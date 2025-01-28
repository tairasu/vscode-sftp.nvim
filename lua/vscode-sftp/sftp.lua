local config = require("vscode-sftp.config")
local async = require("plenary.async")

local M = {}

local function get_password(prompt)
  vim.fn.inputsave()
  local password = vim.fn.inputsecret(prompt)
  vim.fn.inputrestore()
  return password
end

local function build_connection_string(context)
  if context.privateKeyPath then
    return string.format(
      "set sftp:connect-program 'ssh -a -x -i %s'; open sftp://%s@%s:%d",
      context.privateKeyPath,
      context.username,
      context.host,
      context.port
    )
  else
    local password = context.password or get_password("SFTP Password for " .. context.host .. ": ")
    return string.format(
      "set sftp:password '%s'; open sftp://%s@%s:%d",
      password,
      context.username,
      context.host,
      context.port
    )
  end
end

function M.upload_current_file()
  local config_path = config.find_config()
  if not config_path then
    vim.notify("No sftp.json found", vim.log.levels.WARN)
    return
  end

  local conf = config.parse_config(config_path)
  local current_file = vim.fn.expand("%:p")
  local relative_path = vim.fn.fnamemodify(
    current_file, ":." .. vim.fn.fnamemodify(config_path, ":h:h")
  )

  for _, context in pairs(conf.contexts) do
    async.void(function()
      local connection_cmd = build_connection_string(context)
      local remote_file = context.remotePath .. "/" .. relative_path
      
      local cmd = string.format(
        "lftp -e '%s; put %s -o %s; bye'",
        connection_cmd,
        current_file,
        remote_file
      )

      local handle = vim.fn.jobstart(cmd, {
        on_exit = function(_, code, _)
          if code == 0 then
            vim.notify("Uploaded to " .. (context.name or context.host), vim.log.levels.INFO)
          else
            vim.notify("Upload failed with code " .. code, vim.log.levels.ERROR)
          end
        end
      })
      
      if handle == 0 or handle == -1 then
        vim.notify("Failed to start upload job", vim.log.levels.ERROR)
      end
    end)()
  end
end

function M.download_file()
  local config_path = config.find_config()
  if not config_path then
    vim.notify("No sftp.json found", vim.log.levels.WARN)
    return
  end

  local conf = config.parse_config(config_path)
  local current_file = vim.fn.expand("%:p")
  local relative_path = vim.fn.fnamemodify(
    current_file, ":." .. vim.fn.fnamemodify(config_path, ":h:h")
  )

  for _, context in pairs(conf.contexts) do
    async.void(function()
      local conn_str, auth = build_connection_string(context)
      local remote_file = context.remotePath .. "/" .. relative_path
      
      -- Create local directory structure if needed
      local dir = vim.fn.fnamemodify(current_file, ":h")
      vim.fn.mkdir(dir, "p")

      local cmd = string.format(
        "lftp -e '%s get %s -o %s; quit' %s",
        auth,
        remote_file,
        current_file,
        conn_str
      )

      local result = vim.fn.system(cmd)
      if vim.v.shell_error ~= 0 then
        vim.notify("Download failed: " .. result, vim.log.levels.ERROR)
      else
        vim.notify("Downloaded from " .. (context.name or context.host), vim.log.levels.INFO)
      end
    end)()
  end
end

return M
