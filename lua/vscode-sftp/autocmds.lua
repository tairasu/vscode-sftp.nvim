local M = {}

local config = require('vscode-sftp.config')
local sftp = require('vscode-sftp.sftp')

function M.setup()
    local group = vim.api.nvim_create_augroup('VscodeSFTP', { clear = true })
    
    -- Auto upload on save
    vim.api.nvim_create_autocmd('BufWritePost', {
        group = group,
        pattern = '*',
        callback = function()
            -- Check if auto upload is enabled globally
            if not require('vscode-sftp').config.auto_upload then
                return
            end
            
            -- Get SFTP config for current file
            local conf = config.find_config()
            if not conf then
                return
            end
            
            -- Check if uploadOnSave is enabled in the config
            if conf.uploadOnSave == false then
                return
            end
            
            -- Get the current file path relative to the workspace root
            local current_file = vim.fn.expand('%:p')
            
            -- Check if file is in ignore list
            if conf.ignore then
                for _, pattern in ipairs(conf.ignore) do
                    if current_file:match(pattern) then
                        return
                    end
                end
            end
            
            -- Upload the file
            sftp.upload_current_file()
        end
    })
end

return M 