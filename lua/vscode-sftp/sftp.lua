local config = require("vscode-sftp.config")
local async = require("plenary.async")

local M = {}

function M.upload_current_file()
  local config_path = config.find_config()
  if not config_path then
    vim.notify("No sftp.json found", vim.log.levels.WARN)
    return
  end

  local conf = config.parse_config(config_path)
  local current_file = vim.fn.expand("%:p")
  local relative_path = vim.fn.fnamemodify(
    current_file, ":" .. #vim.fn.fnamemodify(config_path, ":h:h") + 2
  )

  -- Implement multi-environment support
  for _, context in pairs(conf.contexts or {}) do
    if context.remotePath then
      async.void(function()
        local cmd = string.format(
          "lftp -e 'put %s -o %s/%s; quit' %s",
          current_file,
          context.remotePath,
          relative_path,
          context.host
        )
        
        vim.fn.system(cmd)
        vim.notify("Uploaded to " .. context.name, vim.log.levels.INFO)
      end)()
    end
  end
end

return M
