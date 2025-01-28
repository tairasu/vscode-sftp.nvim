if vim.g.loaded_vscode_sftp then
    return
end
vim.g.loaded_vscode_sftp = true

-- Load and setup the plugin
require('vscode-sftp').setup() 