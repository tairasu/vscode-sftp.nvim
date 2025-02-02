local M = {}

local config = require('vscode-sftp.config')
local Job = require('plenary.job')
local Path = require('plenary.path')

local execute_sftp_command -- forward declaration

-- Debug logging function
local function debug_log(msg, conf)
    if conf and conf.debug then
        vim.schedule(function()
            vim.notify("[SFTP Debug] " .. msg, vim.log.levels.DEBUG)
        end)
    end
end

-- Create mkdir commands for each directory in the path
local function create_mkdir_commands(path)
    -- Skip if path is '.' or empty
    if path == '.' or path == '' then
        return ''
    end
    
    local parts = vim.split(path, '/', { plain = true })
    local commands = {}
    local current = ''
    
    for _, part in ipairs(parts) do
        if part ~= '' then
            current = (current == '') and part or current .. '/' .. part
            -- Use -mkdir instead of mkdir to ignore errors if directory exists
            table.insert(commands, '-mkdir ' .. vim.fn.shellescape(current))
        end
    end
    
    return table.concat(commands, '\n')
end

-- Get remote path for a local file
local function get_remote_path(conf, local_path)
    local workspace_root = vim.fn.getcwd()
    local relative_path = Path:new(local_path):make_relative(workspace_root)
    return Path:new(conf.remotePath):joinpath(relative_path).filename
end

-- Create SFTP batch commands
local function create_sftp_commands(conf)
    local commands = {}
    
    -- Add connection details
    if conf.privateKeyPath then
        local key_path = vim.fn.expand(conf.privateKeyPath)
        -- Check if the key file exists and has correct permissions
        if vim.fn.filereadable(key_path) == 0 then
            error("SSH key file not found: " .. key_path)
        end
        
        -- Add identity file
        table.insert(commands, "-i")
        table.insert(commands, key_path)
        
        -- Add options for strict host key checking
        table.insert(commands, "-o")
        table.insert(commands, "StrictHostKeyChecking=no")
    end
    
    -- Add port if not default
    if conf.port ~= 22 then
        table.insert(commands, "-P")
        table.insert(commands, tostring(conf.port))
    end
    
    -- Add destination in the format username@host
    table.insert(commands, conf.username .. "@" .. conf.host)
    
    return commands
end

-- Helper: Recursively retrieve remote file listing using "ls -l"
local function walk_remote_dir(conf, dir, callback)
    -- Build a batch command that changes to the directory, lists its contents, then quits.
    local batch_cmd = string.format("cd %s\nls -l\nquit\n", vim.fn.shellescape(dir))
    
    execute_sftp_command(conf, batch_cmd, function(success, output)
        if not success then
            callback(false, {})
            return
        end

        local results = {}  -- will store file information
        
        -- Parse each line that is not the prompt, blank, or a "total" line.
        for _, line in ipairs(output) do
            if not line:match("^sftp>") and line ~= "" and not line:match("^total") then
                local perm, links, user, group, size, month, day, time_or_year, name =
                    line:match("^(%S+)%s+([%d%?]+)%s+(%S+)%s+(%S+)%s+(%d+)%s+(%a+)%s+(%d+)%s+(%S+)%s+(.+)$")

                if perm and name then
                    local months = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
                                     Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
                    local m = months[month] or 1
                    local year, hour, min
                    if time_or_year:find(":") then
                        year = tonumber(os.date("%Y"))
                        hour, min = time_or_year:match("^(%d+):(%d+)$")
                    else
                        year = tonumber(time_or_year)
                        hour, min = 0, 0
                    end
                    day = tonumber(day) or 1
                    local file_mtime = os.time({
                        year = year,
                        month = m,
                        day = day,
                        hour = tonumber(hour) or 0,
                        min = tonumber(min) or 0,
                        sec = 0
                    })

                    -- Store file info in results with full path as key
                    local full_path = dir .. "/" .. name
                    results[full_path] = {
                        mtime = file_mtime,
                        size = tonumber(size)
                    }
                end
            end
        end
        
        callback(true, results)
    end)
end

-- Updated function to retrieve the full remote file listing recursively.
local function get_remote_file_list(conf, callback)
    walk_remote_dir(conf, conf.remotePath, function(success, listing)
        if not success then
            callback(nil)
        else
            callback(listing)
        end
    end)
end

-- Execute SFTP command with password support
execute_sftp_command = function(conf, command, callback)
    local args = create_sftp_commands(conf)
    local output = {}
    local errors = {}
    
    debug_log("SFTP command args: " .. vim.inspect(args), conf)
    
    -- Create a temporary script file for batch commands
    local temp_script = vim.fn.tempname()
    local f = io.open(temp_script, 'w')
    if not f then
        vim.schedule(function()
            vim.notify('Failed to create temporary script file', vim.log.levels.ERROR)
        end)
        return
    end
    
    -- Add remote directory change command at the start:
    -- Ensure that the remote path exists and change directory to it.
    local setup_cmds = string.format('-mkdir %s\ncd %s\n',
        vim.fn.shellescape(conf.remotePath),
        vim.fn.shellescape(conf.remotePath)
    )
    f:write(setup_cmds)
    f:write(command)
    -- Append a "quit" command to force exit and flush output.
    f:write("quit\n")
    f:close()
    
    debug_log("Batch commands:\n" .. setup_cmds .. command .. "quit\n", conf)
    
    -- Add the batch file argument
    table.insert(args, 1, "-b")
    table.insert(args, 2, temp_script)
    
    local job = Job:new({
        command = 'sftp',
        args = args,
        on_stdout = function(_, data)
            if data then
                table.insert(output, data)
                debug_log("STDOUT: " .. data, conf)
            end
        end,
        on_stderr = function(_, data)
            if data then
                -- Filter out "Couldn't create directory" messages when using -mkdir
                if not data:match("Couldn't create directory") and
                   not data:match("remote mkdir.*: Failure") and
                   not data:match("stat.*: No such file or directory") then
                    table.insert(errors, data)
                    debug_log("STDERR: " .. data, conf)
                end
            end
        end,
        on_exit = function(j, return_val)
            -- Schedule both the file deletion and callback to avoid E5560
            vim.schedule(function()
                -- Clean up temp file
                os.remove(temp_script)
                
                -- Consider the operation successful if there are no real errors
                -- (ignoring mkdir failures and stat failures)
                if return_val == 0 or #errors == 0 then
                    callback(true, output)
                else
                    -- Check for common error patterns
                    local error_msg = table.concat(errors, "\n")
                    if error_msg:match("Permission denied") then
                        if conf.privateKeyPath then
                            error_msg = error_msg .. "\nPossible issues:\n" ..
                                      "1. Check SSH key permissions (should be 600)\n" ..
                                      "2. Verify the key is added to the server\n" ..
                                      "3. Ensure remote user has write permissions"
                        else
                            error_msg = error_msg .. "\nPossible issues:\n" ..
                                      "1. Check username/password\n" ..
                                      "2. Ensure remote user has write permissions"
                        end
                    end
                    callback(false, {error_msg})
                end
            end)
        end
    })
    
    -- If password is provided, prepare it for input
    if conf.password then
        job:start()
        vim.schedule(function()
            job:send(conf.password .. "\n")
        end)
    else
        job:start()
    end
end

-- Upload a file to remote
function M.upload_current_file()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    local current_file = vim.fn.expand('%:p')
    local relative_path = Path:new(current_file):make_relative(vim.fn.getcwd())
    
    -- Create remote directory structure and upload file
    local remote_dir = vim.fn.fnamemodify(relative_path, ':h')
    local batch_cmd = ''
    
    -- Add mkdir commands for directory structure
    if remote_dir ~= '.' then
        batch_cmd = create_mkdir_commands(remote_dir) .. '\n'
    end
    
    -- Add put command (no cd needed for simple uploads)
    if remote_dir == '.' then
        batch_cmd = batch_cmd .. string.format('put %s\n',
            vim.fn.shellescape(current_file)
        )
    else
        batch_cmd = batch_cmd .. string.format('put %s %s/%s\n',
            vim.fn.shellescape(current_file),
            vim.fn.shellescape(remote_dir),
            vim.fn.shellescape(vim.fn.fnamemodify(current_file, ':t'))
        )
    end
    
    execute_sftp_command(conf, batch_cmd, function(success, output)
        if success then
            vim.notify(string.format('Uploaded %s', current_file), vim.log.levels.INFO)
        else
            vim.notify(string.format('Failed to upload %s: %s', current_file, table.concat(output, '\n')), vim.log.levels.ERROR)
        end
    end)
end

-- Helper: Build batch command to download a given file
local function add_download_command(file)
    local remote_dir = vim.fn.fnamemodify(file, ':h')
    local local_path = file
    local cmd = ""
    
    -- Create local directory if needed
    vim.fn.mkdir(vim.fn.fnamemodify(local_path, ':h'), 'p')
    
    if remote_dir == '.' or remote_dir == '' then
        cmd = string.format("get %s %s\n",
            vim.fn.shellescape(vim.fn.fnamemodify(file, ':t')),
            vim.fn.shellescape(local_path))
    else
        cmd = string.format("cd %s\nget %s %s\ncd ..\n",
            vim.fn.shellescape(remote_dir),
            vim.fn.shellescape(vim.fn.fnamemodify(file, ':t')),
            vim.fn.shellescape(local_path)
        )
    end
    return cmd
end

-- Download a file from remote with selection
function M.download_current_file()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    local current_file = vim.fn.expand('%:p')
    local current_dir = vim.fn.fnamemodify(current_file, ':h')
    local relative_dir = Path:new(current_dir):make_relative(vim.fn.getcwd())
    
    -- Get remote file listing
    get_remote_file_list(conf, function(remote_listing)
        if not remote_listing then
            vim.notify("Failed to retrieve remote file list", vim.log.levels.ERROR)
            return
        end
        
        -- Collect available files in current directory
        local available_files = {}
        for remote_file, info in pairs(remote_listing) do
            if remote_file:sub(1, #conf.remotePath + 1) == conf.remotePath .. "/" then
                local relative_file = remote_file:sub(#conf.remotePath + 2)
                local file_dir = vim.fn.fnamemodify(relative_file, ':h')
                
                -- Check if file is in current directory
                if file_dir == relative_dir or (file_dir == '.' and relative_dir == '') then
                    table.insert(available_files, {
                        name = vim.fn.fnamemodify(relative_file, ':t'),
                        path = relative_file,
                        info = info
                    })
                end
            end
        end
        
        if #available_files == 0 then
            vim.notify("No files found in remote directory", vim.log.levels.ERROR)
            return
        end
        
        -- Sort files by name
        table.sort(available_files, function(a, b) return a.name < b.name end)
        
        -- Create selection items with file info
        local items = {}
        for _, file in ipairs(available_files) do
            table.insert(items, string.format("%s (%s, %d bytes)",
                file.name,
                format_timestamp(file.info.mtime),
                file.info.size
            ))
        end
        
        -- Show file selection
        vim.ui.select(items, {
            prompt = "Select file to download:",
            format_item = function(item) return item end
        }, function(choice, idx)
            if not choice then
                vim.notify("Download cancelled", vim.log.levels.INFO)
                return
            end
            
            local file = available_files[idx]
            local local_path = file.path
            
            -- Create local directory structure
            vim.fn.mkdir(vim.fn.fnamemodify(local_path, ':h'), 'p')
            
            -- Download file
            local batch_cmd = add_download_command(file.path)
            execute_sftp_command(conf, batch_cmd, function(success, output)
                if success then
                    vim.notify(string.format('Downloaded %s', file.path), vim.log.levels.INFO)
                    -- Reload buffer if we downloaded the current file
                    if file.path == vim.fn.expand('%:p') then
                        vim.cmd('e!')
                    end
                else
                    vim.notify(string.format('Failed to download %s: %s', file.path, table.concat(output, '\n')), vim.log.levels.ERROR)
                end
            end)
        end)
    end)
end

-- Helper: Build batch command to upload a given file
local function add_upload_command(file)
    local remote_dir = vim.fn.fnamemodify(file, ':h')
    local cmd = ""
    if remote_dir == '.' or remote_dir == '' then
        cmd = string.format("put %s\n", vim.fn.shellescape(file))
    else
        cmd = create_mkdir_commands(remote_dir) .. "\n" ..
              string.format("cd %s\nput %s\ncd ..\n",
                vim.fn.shellescape(remote_dir),
                vim.fn.shellescape(vim.fn.fnamemodify(file, ':t'))
              )
    end
    return cmd
end

-- Helper: Format file size difference
local function format_size_diff(new_size, old_size)
    local diff = new_size - old_size
    local abs_diff = math.abs(diff)
    local sign = diff >= 0 and "+" or "-"
    
    if abs_diff < 1024 then
        return string.format("%s%d B", sign, abs_diff)
    elseif abs_diff < 1024 * 1024 then
        return string.format("%s%.1f KB", sign, abs_diff / 1024)
    else
        return string.format("%s%.1f MB", sign, abs_diff / (1024 * 1024))
    end
end

-- Helper: Format timestamp
local function format_timestamp(timestamp)
    return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

-- Helper: Get file info string
local function get_file_info_string(file, old_mtime, old_size, new_mtime, new_size)
    return string.format("%s\n  Old: %s (%d bytes)\n  New: %s (%d bytes) (%s)",
        file,
        format_timestamp(old_mtime),
        old_size,
        format_timestamp(new_mtime),
        new_size,
        format_size_diff(new_size, old_size)
    )
end

-- Download all files in current directory
function M.download_directory()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    local current_file = vim.fn.expand('%:p')
    local current_dir = vim.fn.fnamemodify(current_file, ':h')
    local relative_dir = Path:new(current_dir):make_relative(vim.fn.getcwd())
    
    -- First, get remote file listing
    get_remote_file_list(conf, function(remote_listing)
        if not remote_listing then
            vim.notify("Failed to retrieve remote file list", vim.log.levels.ERROR)
            return
        end
        
        -- Collect files to download
        local files_to_download = {}
        local total_download_size = 0
        
        for remote_file, info in pairs(remote_listing) do
            if remote_file:sub(1, #conf.remotePath + 1) == conf.remotePath .. "/" then
                local relative_file = remote_file:sub(#conf.remotePath + 2)
                local file_dir = vim.fn.fnamemodify(relative_file, ':h')
                
                -- Check if file is in current directory
                if file_dir == relative_dir or (file_dir == '.' and relative_dir == '') then
                    local local_path = relative_file
                    local local_mtime = vim.fn.getftime(local_path)
                    local local_size = vim.fn.getfsize(local_path)
                    
                    -- If file doesn't exist locally or is older
                    if local_mtime == -1 or local_mtime < info.mtime then
                        table.insert(files_to_download, {
                            remote_file = relative_file,
                            local_path = local_path,
                            info = info,
                            local_mtime = local_mtime == -1 and 0 or local_mtime,
                            local_size = local_size == -1 and 0 or local_size
                        })
                        total_download_size = total_download_size + info.size
                    end
                end
            end
        end
        
        if #files_to_download == 0 then
            vim.notify("No files to download in current directory", vim.log.levels.INFO)
            return
        end
        
        -- Sort files by name
        table.sort(files_to_download, function(a, b) 
            return vim.fn.fnamemodify(a.remote_file, ':t') < vim.fn.fnamemodify(b.remote_file, ':t')
        end)
        
        -- Build summary message
        local summary = string.format("The following %d files will be downloaded (total %d bytes) to %s:\n\n",
            #files_to_download, total_download_size, relative_dir)
        
        for _, file in ipairs(files_to_download) do
            local filename = vim.fn.fnamemodify(file.remote_file, ':t')
            summary = summary .. string.format("  • %s\n    Remote: %s (%d bytes)\n    Local: %s (%d bytes)\n\n",
                filename,
                format_timestamp(file.info.mtime),
                file.info.size,
                file.local_mtime == 0 and "Not found" or format_timestamp(file.local_mtime),
                file.local_size
            )
        end
        
        -- Ask for confirmation
        vim.ui.select({'Yes', 'No'}, {
            prompt = summary .. "\nProceed with download?",
            default = 'No'
        }, function(choice)
            if choice ~= 'Yes' then
                vim.notify("Download cancelled", vim.log.levels.INFO)
                return
            end
            
            -- Download files
            for _, file in ipairs(files_to_download) do
                local batch_cmd = add_download_command(file.remote_file)
                execute_sftp_command(conf, batch_cmd, function(success, output)
                    if success then
                        vim.notify(string.format('Downloaded %s', file.remote_file), vim.log.levels.INFO)
                        -- Reload buffer if the current file was downloaded
                        if file.remote_file == vim.fn.expand('%:p') then
                            vim.cmd('e!')
                        end
                    else
                        vim.notify(string.format('Failed to download %s: %s',
                            file.remote_file, table.concat(output, '\n')), vim.log.levels.ERROR)
                    end
                end)
            end
        end)
    end)
end

-- Upload all files in current directory
function M.upload_directory()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    local current_file = vim.fn.expand('%:p')
    local current_dir = vim.fn.fnamemodify(current_file, ':h')
    local relative_dir = Path:new(current_dir):make_relative(vim.fn.getcwd())
    
    -- Get local files
    local local_files = vim.fn.systemlist(string.format("find '%s' -type f -maxdepth 1", current_dir))
    if #local_files == 0 then
        vim.notify("No files found in current directory", vim.log.levels.INFO)
        return
    end
    
    -- Get remote file listing for comparison
    get_remote_file_list(conf, function(remote_listing)
        if not remote_listing then
            vim.notify("Failed to retrieve remote file list", vim.log.levels.ERROR)
            return
        end
        
        -- Collect files to upload
        local files_to_upload = {}
        local total_upload_size = 0
        
        for _, local_path in ipairs(local_files) do
            local relative_path = Path:new(local_path):make_relative(vim.fn.getcwd())
            local remote_key = conf.remotePath .. "/" .. relative_path
            local local_mtime = vim.fn.getftime(local_path)
            local local_size = vim.fn.getfsize(local_path)
            
            local remote_info = remote_listing[remote_key]
            if not remote_info or local_mtime > remote_info.mtime then
                table.insert(files_to_upload, {
                    local_path = local_path,
                    relative_path = relative_path,
                    local_mtime = local_mtime,
                    local_size = local_size,
                    remote_info = remote_info or { mtime = 0, size = 0 }
                })
                total_upload_size = total_upload_size + local_size
            end
        end
        
        if #files_to_upload == 0 then
            vim.notify("No files to upload in current directory", vim.log.levels.INFO)
            return
        end
        
        -- Build summary message
        local summary = string.format("Will upload %d files (total %d bytes) from %s:\n",
            #files_to_upload, total_upload_size, relative_dir)
        for _, file in ipairs(files_to_upload) do
            summary = summary .. get_file_info_string(
                vim.fn.fnamemodify(file.local_path, ':t'),
                file.remote_info.mtime,
                file.remote_info.size,
                file.local_mtime,
                file.local_size
            ) .. "\n"
        end
        
        -- Ask for confirmation
        vim.ui.select({'Yes', 'No'}, {
            prompt = summary .. "\nProceed with upload?",
            default = 'No'
        }, function(choice)
            if choice ~= 'Yes' then
                vim.notify("Upload cancelled", vim.log.levels.INFO)
                return
            end
            
            -- Upload files
            for _, file in ipairs(files_to_upload) do
                local batch_cmd = add_upload_command(file.relative_path)
                execute_sftp_command(conf, batch_cmd, function(success, output)
                    if success then
                        vim.notify(string.format('Uploaded %s', file.relative_path), vim.log.levels.INFO)
                    else
                        vim.notify(string.format('Failed to upload %s: %s',
                            file.relative_path, table.concat(output, '\n')), vim.log.levels.ERROR)
                    end
                end)
            end
        end)
    end)
end

-- Sync entire project bidirectionally (only newest files)
function M.sync_project()
    local conf = config.find_config()
    if not conf then
        vim.notify("No SFTP configuration found", vim.log.levels.ERROR)
        return
    end

    -- Get remote file listing first
    get_remote_file_list(conf, function(remote_listing)
        if not remote_listing then
            vim.notify("Failed to retrieve remote file list", vim.log.levels.ERROR)
            return
        end

        -- Get the local file list
        local files = vim.fn.systemlist("git ls-files 2>/dev/null || find . -type f")
        local files_to_sync = {}
        local total_sync_size = 0
        
        -- Compare each file
        for _, local_path in ipairs(files) do
            -- Skip ignored files
            local skip = false
            if conf.ignore then
                for _, pattern in ipairs(conf.ignore) do
                    if local_path:match(pattern) then
                        skip = true
                        break
                    end
                end
            end
            
            if not skip then
                local remote_key = conf.remotePath .. "/" .. local_path
                local local_mtime = vim.fn.getftime(local_path)
                local local_size = vim.fn.getfsize(local_path)
                local remote_info = remote_listing[remote_key]
                
                if remote_info then
                    -- File exists on both sides
                    if local_mtime > remote_info.mtime then
                        -- Local is newer
                        table.insert(files_to_sync, {
                            path = local_path,
                            action = "upload",
                            old_mtime = remote_info.mtime,
                            new_mtime = local_mtime,
                            old_size = remote_info.size,
                            new_size = local_size
                        })
                        total_sync_size = total_sync_size + local_size
                    elseif remote_info.mtime > local_mtime then
                        -- Remote is newer
                        table.insert(files_to_sync, {
                            path = local_path,
                            action = "download",
                            old_mtime = local_mtime,
                            new_mtime = remote_info.mtime,
                            old_size = local_size,
                            new_size = remote_info.size
                        })
                        total_sync_size = total_sync_size + remote_info.size
                    end
                else
                    -- File only exists locally
                    table.insert(files_to_sync, {
                        path = local_path,
                        action = "upload",
                        old_mtime = 0,
                        new_mtime = local_mtime,
                        old_size = 0,
                        new_size = local_size
                    })
                    total_sync_size = total_sync_size + local_size
                end
            end
        end
        
        -- Check for files that only exist remotely
        for remote_file, info in pairs(remote_listing) do
            if remote_file:sub(1, #conf.remotePath + 1) == conf.remotePath .. "/" then
                local relative_file = remote_file:sub(#conf.remotePath + 2)
                if vim.fn.filereadable(relative_file) == 0 then
                    -- Skip ignored files
                    local skip = false
                    if conf.ignore then
                        for _, pattern in ipairs(conf.ignore) do
                            if relative_file:match(pattern) then
                                skip = true
                                break
                            end
                        end
                    end
                    
                    if not skip then
                        table.insert(files_to_sync, {
                            path = relative_file,
                            action = "download",
                            old_mtime = 0,
                            new_mtime = info.mtime,
                            old_size = 0,
                            new_size = info.size
                        })
                        total_sync_size = total_sync_size + info.size
                    end
                end
            end
        end
        
        if #files_to_sync == 0 then
            vim.notify("Everything is already in sync", vim.log.levels.INFO)
            return
        end
        
        -- Build summary message
        local summary = string.format("Will sync %d files (total %d bytes):\n",
            #files_to_sync, total_sync_size)
        for _, file in ipairs(files_to_sync) do
            summary = summary .. string.format("[%s] %s\n",
                file.action:upper(),
                get_file_info_string(
                    file.path,
                    file.old_mtime,
                    file.old_size,
                    file.new_mtime,
                    file.new_size
                )
            ) .. "\n"
        end
        
        -- Ask for confirmation
        vim.ui.select({'Yes', 'No'}, {
            prompt = summary .. "\nProceed with sync?",
            default = 'No'
        }, function(choice)
            if choice ~= 'Yes' then
                vim.notify("Sync cancelled", vim.log.levels.INFO)
                return
            end
            
            -- Perform sync operations
            for _, file in ipairs(files_to_sync) do
                local batch_cmd
                if file.action == "upload" then
                    batch_cmd = add_upload_command(file.path)
                else
                    vim.fn.mkdir(vim.fn.fnamemodify(file.path, ":h"), "p")
                    batch_cmd = add_download_command(file.path)
                end
                
                execute_sftp_command(conf, batch_cmd, function(success, output)
                    if success then
                        vim.notify(string.format('Synced (%s): %s', file.action, file.path), vim.log.levels.INFO)
                        -- Reload buffer if current file was downloaded
                        if file.action == "download" and file.path == vim.fn.expand('%:p') then
                            vim.cmd('e!')
                        end
                    else
                        vim.notify(string.format('Failed to %s %s: %s',
                            file.action, file.path, table.concat(output, '\n')), vim.log.levels.ERROR)
                    end
                end)
            end
        end)
    end)
end

-- Delete remote file/directory
function M.delete_remote()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    local current_file = vim.fn.expand('%:p')
    local relative_path = Path:new(current_file):make_relative(vim.fn.getcwd())
    
    local remote_dir = vim.fn.fnamemodify(relative_path, ':h')
    local batch_cmd = string.format('cd %s\nrm %s\n',
        vim.fn.shellescape(remote_dir),
        vim.fn.shellescape(vim.fn.fnamemodify(current_file, ':t'))
    )
    
    execute_sftp_command(conf, batch_cmd, function(success, output)
        if success then
            vim.notify(string.format('Deleted %s', current_file), vim.log.levels.INFO)
        else
            vim.notify(string.format('Failed to delete %s: %s', current_file, table.concat(output, '\n')), vim.log.levels.ERROR)
        end
    end)
end

return M

