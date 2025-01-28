local M = {}

local config = require('vscode-sftp.config')
local sftp = require('vscode-sftp.sftp')

local function create_sftp_json()
    local template = {
        name = "My Server",
        host = "hostname",
        protocol = "sftp",
        port = 22,
        username = "username",
        remotePath = "/path/to/remote/project",
        uploadOnSave = true,
        ignore = {
            ".vscode",
            ".git",
            ".DS_Store",
            "node_modules",
            "dist"
        }
    }
    
    -- Create .vscode directory if it doesn't exist
    local vscode_dir = '.vscode'
    if vim.fn.isdirectory(vscode_dir) == 0 then
        vim.fn.mkdir(vscode_dir, 'p')
    end
    
    -- Write the template to sftp.json
    local config_path = vscode_dir .. '/sftp.json'
    if vim.fn.filereadable(config_path) == 1 then
        vim.notify('sftp.json already exists!', vim.log.levels.WARN)
        return
    end
    
    local f = io.open(config_path, 'w')
    if not f then
        vim.notify('Failed to create sftp.json', vim.log.levels.ERROR)
        return
    end
    
    f:write(vim.fn.json_encode(template))
    f:close()
    
    vim.notify('Created sftp.json template', vim.log.levels.INFO)
end

function M.setup()
    -- Create user commands
    vim.api.nvim_create_user_command('SFTPUpload', function()
        local conf = config.find_config()
        if not conf then
            vim.notify('No sftp.json configuration found', vim.log.levels.ERROR)
            return
        end
        sftp.upload_current_file()
    end, {})
    
    vim.api.nvim_create_user_command('SFTPDownload', function()
        local conf = config.find_config()
        if not conf then
            vim.notify('No sftp.json configuration found', vim.log.levels.ERROR)
            return
        end
        sftp.download_current_file()
    end, {})
    
    vim.api.nvim_create_user_command('SFTPSync', function()
        local conf = config.find_config()
        if not conf then
            vim.notify('No sftp.json configuration found', vim.log.levels.ERROR)
            return
        end
        sftp.sync_project()
    end, {})
    
    vim.api.nvim_create_user_command('SFTPInit', function()
        create_sftp_json()
    end, {})
    
    vim.api.nvim_create_user_command('SFTPDelete', function()
        local conf = config.find_config()
        if not conf then
            vim.notify('No sftp.json configuration found', vim.log.levels.ERROR)
            return
        end
        sftp.delete_remote()
    end, {})
end

return M 