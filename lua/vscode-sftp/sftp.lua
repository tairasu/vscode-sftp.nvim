local M = {}

local config = require('vscode-sftp.config')
local ssh = require('ssh')
local Path = require('plenary.path')

-- Cache for SFTP connections
local connections = {}

-- Get or create an SFTP connection for a config
local function get_connection(conf)
    local key = conf.host .. ':' .. conf.port .. ':' .. conf.username
    
    if connections[key] then
        return connections[key]
    end
    
    -- Create new connection
    local conn_config = {
        host = conf.host,
        port = conf.port,
        user = conf.username
    }
    
    -- Add authentication method
    if conf.password then
        conn_config.password = conf.password
    elseif conf.privateKeyPath then
        conn_config.private_key = vim.fn.expand(conf.privateKeyPath)
    end
    
    local connection = ssh.create_connection(conn_config)
    connections[key] = connection
    
    return connection
end

-- Get remote path for a local file
local function get_remote_path(conf, local_path)
    local workspace_root = vim.fn.getcwd()
    local relative_path = Path:new(local_path):make_relative(workspace_root)
    return Path:new(conf.remotePath):joinpath(relative_path).filename
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
    
    local conn = get_connection(conf)
    
    -- Ensure remote directory exists
    local remote_dir = vim.fn.fnamemodify(remote_path, ':h')
    conn:execute('mkdir -p ' .. vim.fn.shellescape(remote_dir))
    
    -- Upload file
    local success = conn:upload(current_file, remote_path)
    
    if success then
        vim.notify(string.format('Uploaded %s to %s', current_file, remote_path), vim.log.levels.INFO)
    else
        vim.notify(string.format('Failed to upload %s', current_file), vim.log.levels.ERROR)
    end
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
    
    local conn = get_connection(conf)
    
    -- Download file
    local success = conn:download(remote_path, current_file)
    
    if success then
        vim.notify(string.format('Downloaded %s from %s', current_file, remote_path), vim.log.levels.INFO)
        -- Reload the buffer to show new contents
        vim.cmd('e!')
    else
        vim.notify(string.format('Failed to download %s', current_file), vim.log.levels.ERROR)
    end
end

-- Sync entire project
function M.sync_project()
    local conf = config.find_config()
    if not conf then
        vim.notify('No SFTP configuration found', vim.log.levels.ERROR)
        return
    end
    
    local conn = get_connection(conf)
    local workspace_root = vim.fn.getcwd()
    
    -- Create a list of files to sync
    local files = vim.fn.systemlist('git ls-files 2>/dev/null || find . -type f')
    local count = 0
    local errors = 0
    
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
            
            -- Ensure remote directory exists
            local remote_dir = vim.fn.fnamemodify(remote_path, ':h')
            conn:execute('mkdir -p ' .. vim.fn.shellescape(remote_dir))
            
            -- Upload file
            local success = conn:upload(local_path, remote_path)
            if success then
                count = count + 1
            else
                errors = errors + 1
            end
        end
    end
    
    vim.notify(string.format('Sync complete: %d files uploaded, %d errors', count, errors), 
              errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
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
    
    local conn = get_connection(conf)
    
    -- Delete file
    local success = conn:execute('rm -rf ' .. vim.fn.shellescape(remote_path))
    
    if success then
        vim.notify(string.format('Deleted %s', remote_path), vim.log.levels.INFO)
    else
        vim.notify(string.format('Failed to delete %s', remote_path), vim.log.levels.ERROR)
    end
end

return M
