local M = {}

local config = require('vscode-sftp.config')
local Job = require('plenary.job')
local Path = require('plenary.path')

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

-- Execute SFTP command with password support
local function execute_sftp_command(conf, command, callback)
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
    
    -- Add remote directory change command at the start
    -- Use -mkdir to create the remote path if it doesn't exist
    local setup_cmds = string.format('-mkdir %s\ncd %s\n',
        vim.fn.shellescape(conf.remotePath),
        vim.fn.shellescape(conf.remotePath)
    )
    f:write(setup_cmds)
    f:write(command)
    f:close()
    
    debug_log("Batch commands:\n" .. setup_cmds .. command, conf)
    
    -- Add the batch file argument
    table.insert(args, 1, "-b")  -- Insert at the beginning
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
                if not data:match("Couldn't create directory") then
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
    
    -- Add cd and put commands
    batch_cmd = batch_cmd .. string.format('cd %s\nput %s\n', 
        vim.fn.shellescape(remote_dir),
        vim.fn.shellescape(vim.fn.fnamemodify(current_file, ':t'))
    )
    
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

-- Sync entire project
function M.sync_project()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    -- Create a list of files to sync
    local files = vim.fn.systemlist('git ls-files 2>/dev/null || find . -type f')
    local total = #files
    
    -- Create batch upload command
    local batch_cmd = ''
    for _, file in ipairs(files) do
        -- Skip ignored files
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
            local remote_dir = vim.fn.fnamemodify(file, ':h')
            if remote_dir == '.' then
                batch_cmd = batch_cmd .. string.format('put %s\n',
                    vim.fn.shellescape(file)
                )
            else
                -- Add mkdir commands for directory structure
                batch_cmd = batch_cmd .. create_mkdir_commands(remote_dir) .. '\n'
                -- Add cd and put commands
                batch_cmd = batch_cmd .. string.format('cd %s\nput %s\ncd ..\n',
                    vim.fn.shellescape(remote_dir),
                    vim.fn.shellescape(vim.fn.fnamemodify(file, ':t'))
                )
            end
        end
    end
    
    if batch_cmd ~= '' then
        execute_sftp_command(conf, batch_cmd, function(success, output)
            if success then
                vim.notify(string.format('Sync complete: %d files uploaded', total), vim.log.levels.INFO)
            else
                vim.notify(string.format('Sync failed: %s', table.concat(output, '\n')), vim.log.levels.ERROR)
            end
        end)
    else
        vim.notify('No files to sync', vim.log.levels.INFO)
    end
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
