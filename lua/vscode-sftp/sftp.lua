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

        local entries = {}
        -- Parse each line that is not the prompt, blank, or a "total" line.
        for _, line in ipairs(output) do
            if not line:match("^sftp>") and line ~= "" and not line:match("^total") then
                local perm, links, user, group, size, month, day, time_or_year, name =
                    line:match("^(%S+)%s+(%d+)%s+(%S+)%s+(%S+)%s+(%d+)%s+(%a+)%s+(%d+)%s+(%S+)%s+(.+)$")
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
                    local is_dir = perm:sub(1,1) == "d"
                    table.insert(entries, {
                        name = name,
                        is_dir = is_dir,
                        mtime = file_mtime,
                        size = tonumber(size),
                        path = dir .. "/" .. name
                    })
                end
            end
        end

        local results = {}  -- will accumulate file information from this directory and its children.
        local pending = 0   -- number of recursive calls still pending

        local function finish()
            if pending == 0 then
                callback(true, results)
            end
        end

        -- Add the current directory's entries to results and, if the entry is a directory,
        -- recursively walk it.
        for _, entry in ipairs(entries) do
            results[entry.path] = { mtime = entry.mtime, size = entry.size }
            if entry.is_dir then
                pending = pending + 1
                walk_remote_dir(conf, entry.path, function(succ, sub_entries)
                    for path, info in pairs(sub_entries) do
                        results[path] = info
                    end
                    pending = pending - 1
                    finish()
                end)
            end
        end

        finish()
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

-- Download a file from remote
function M.download_current_file()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    local current_file = vim.fn.expand('%:p')
    local relative_path = Path:new(current_file):make_relative(vim.fn.getcwd())
    
    -- Create local directory structure
    local local_dir = vim.fn.fnamemodify(current_file, ':h')
    vim.fn.mkdir(local_dir, 'p')
    
    -- Download file
    local remote_dir = vim.fn.fnamemodify(relative_path, ':h')
    local batch_cmd = string.format('cd %s\nget %s %s\n',
        vim.fn.shellescape(remote_dir),
        vim.fn.shellescape(vim.fn.fnamemodify(current_file, ':t')),
        vim.fn.shellescape(current_file)
    )
    
    execute_sftp_command(conf, batch_cmd, function(success, output)
        if success then
            vim.notify(string.format('Downloaded %s', current_file), vim.log.levels.INFO)
            vim.cmd('e!') -- Reload the buffer
        else
            vim.notify(string.format('Failed to download %s: %s', current_file, table.concat(output, '\n')), vim.log.levels.ERROR)
        end
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

-- Helper: Build batch command to download a given file
local function add_download_command(file)
    local remote_dir = vim.fn.fnamemodify(file, ':h')
    local cmd = ""
    if remote_dir == '.' or remote_dir == '' then
        cmd = string.format("get %s %s\n",
            vim.fn.shellescape(file), vim.fn.shellescape(file))
    else
        cmd = string.format("cd %s\nget %s %s\ncd ..\n",
            vim.fn.shellescape(remote_dir),
            vim.fn.shellescape(vim.fn.fnamemodify(file, ':t')),
            vim.fn.shellescape(file)
        )
    end
    return cmd
end

-- Sync entire project bidirectionally
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

        -- Get the local file list from git (or fall back to find)
        local files = vim.fn.systemlist("git ls-files 2>/dev/null || find . -type f")
        local filtered_files = {}
        local local_files_map = {}
        
        -- Filter files based on ignore patterns and build local files map
        for _, file in ipairs(files) do
            local skip = false
            if conf.ignore then
                for _, pattern in ipairs(conf.ignore) do
                    if file:match(pattern) then
                        skip = true
                        break
                    end
                end
            end
            if not skip then
                table.insert(filtered_files, file)
                local_files_map[file] = vim.fn.getftime(file)
            end
        end

        -- Find the newest file (both local and remote)
        local newest_file = nil
        local newest_mtime = 0
        local is_remote = false

        -- Check local files
        for file, mtime in pairs(local_files_map) do
            if mtime > newest_mtime then
                newest_mtime = mtime
                newest_file = file
                is_remote = false
            end
        end

        -- Check remote files
        for remote_file, info in pairs(remote_listing) do
            if remote_file:sub(1, #conf.remotePath + 1) == conf.remotePath .. "/" then
                local relative_file = remote_file:sub(#conf.remotePath + 2)
                local remote_mtime = info.mtime or 0

                -- Only consider remote file if it's newer than what we've found
                -- and either doesn't exist locally or is different from local
                local local_mtime = local_files_map[relative_file] or 0
                if remote_mtime > newest_mtime and remote_mtime > local_mtime then
                    newest_mtime = remote_mtime
                    newest_file = relative_file
                    is_remote = true
                end
            end
        end

        if not newest_file then
            vim.notify("Everything is already in sync", vim.log.levels.INFO)
            return
        end

        -- Sync the newest file
        if is_remote then
            -- Download the remote file
            vim.fn.mkdir(vim.fn.fnamemodify(newest_file, ":h"), "p")
            local batch_cmd = add_download_command(newest_file)
            execute_sftp_command(conf, batch_cmd, function(success, output)
                if success then
                    vim.notify("Synced (downloaded): " .. newest_file, vim.log.levels.INFO)
                    -- Reload the buffer if the current file was downloaded
                    if newest_file == vim.fn.expand('%:p') then
                        vim.cmd('e!')
                    end
                else
                    vim.notify("Sync failed: " .. table.concat(output, "\n"), vim.log.levels.ERROR)
                end
            end)
        else
            -- Upload the local file
            local batch_cmd = add_upload_command(newest_file)
            execute_sftp_command(conf, batch_cmd, function(success, output)
                if success then
                    vim.notify("Synced (uploaded): " .. newest_file, vim.log.levels.INFO)
                else
                    vim.notify("Sync failed: " .. table.concat(output, "\n"), vim.log.levels.ERROR)
                end
            end)
        end
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

