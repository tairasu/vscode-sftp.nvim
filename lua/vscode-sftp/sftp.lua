local M = {}

local config = require('vscode-sftp.config')
local Job = require('plenary.job')
local Path = require('plenary.path')

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
        table.insert(commands, "-oIdentityFile=" .. vim.fn.expand(conf.privateKeyPath))
    end
    
    -- Add port if not default
    if conf.port ~= 22 then
        table.insert(commands, "-P")
        table.insert(commands, tostring(conf.port))
    end
    
    -- Add host
    table.insert(commands, conf.username .. "@" .. conf.host)
    
    return commands
end

-- Execute SFTP command
local function execute_sftp_command(conf, command, callback)
    local args = create_sftp_commands(conf)
    local output = {}
    local errors = {}
    
    Job:new({
        command = 'sftp',
        args = args,
        on_stdout = function(_, data)
            table.insert(output, data)
        end,
        on_stderr = function(_, data)
            table.insert(errors, data)
        end,
        on_exit = function(j, return_val)
            if return_val == 0 then
                callback(true, output)
            else
                callback(false, errors)
            end
        end,
        writer = command
    }):start()
end

-- Upload a file to remote
function M.upload_current_file()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    local current_file = vim.fn.expand('%:p')
    local remote_path = get_remote_path(conf, current_file)
    
    -- Create remote directory structure
    local remote_dir = vim.fn.fnamemodify(remote_path, ':h')
    local mkdir_cmd = string.format('-mkdir %s\nput %s %s\n', 
        vim.fn.shellescape(remote_dir),
        vim.fn.shellescape(current_file),
        vim.fn.shellescape(remote_path)
    )
    
    execute_sftp_command(conf, mkdir_cmd, function(success, output)
        if success then
            vim.notify(string.format('Uploaded %s to %s', current_file, remote_path), vim.log.levels.INFO)
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
    local remote_path = get_remote_path(conf, current_file)
    
    -- Create local directory structure
    local local_dir = vim.fn.fnamemodify(current_file, ':h')
    vim.fn.mkdir(local_dir, 'p')
    
    local get_cmd = string.format('get %s %s\n',
        vim.fn.shellescape(remote_path),
        vim.fn.shellescape(current_file)
    )
    
    execute_sftp_command(conf, get_cmd, function(success, output)
        if success then
            vim.notify(string.format('Downloaded %s from %s', current_file, remote_path), vim.log.levels.INFO)
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
    
    local workspace_root = vim.fn.getcwd()
    
    -- Create a list of files to sync
    local files = vim.fn.systemlist('git ls-files 2>/dev/null || find . -type f')
    local count = 0
    local errors = 0
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
            local local_path = Path:new(workspace_root):joinpath(file).filename
            local remote_path = get_remote_path(conf, local_path)
            local remote_dir = vim.fn.fnamemodify(remote_path, ':h')
            
            batch_cmd = batch_cmd .. string.format('-mkdir %s\nput %s %s\n',
                vim.fn.shellescape(remote_dir),
                vim.fn.shellescape(local_path),
                vim.fn.shellescape(remote_path)
            )
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
    local remote_path = get_remote_path(conf, current_file)
    
    local rm_cmd = string.format('rm %s\n', vim.fn.shellescape(remote_path))
    
    execute_sftp_command(conf, rm_cmd, function(success, output)
        if success then
            vim.notify(string.format('Deleted %s', remote_path), vim.log.levels.INFO)
        else
            vim.notify(string.format('Failed to delete %s: %s', remote_path, table.concat(output, '\n')), vim.log.levels.ERROR)
        end
    end)
end

return M
