local sftp = require("vscode-sftp.sftp")

vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*",
  callback = function()
    -- Only upload if config exists
    if require("vscode-sftp.config").find_config() then
      sftp.upload_current_file()
    end
  end,
})

-- Add commands
vim.api.nvim_create_user_command("SFTPUpload", function()
  require("vscode-sftp.sftp").upload_current_file()
end, {})

vim.api.nvim_create_user_command("SFTPDownload", function()
  require("vscode-sftp.sftp").download_file()
end, {})
