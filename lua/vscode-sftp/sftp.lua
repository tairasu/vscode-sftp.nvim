local config = require("vscode-sftp.config")
local async = require("plenary.async")

local M = {}

local function get_password(prompt)
  vim.fn.inputsave()
  local password = vim.fn.inputsecret(prompt or "SFTP Password: ")
  vim.fn.inputrestore()
  return password
end

local function build_connection_string(context)
  local auth = ""
  if context.privateKeyPath then
    auth = string.format("set sftp:connect-program 'ssh -a -x -i %s';", context.privateKeyPath)
  else
    -- Prompt for password if not provided
    local password = context.password or get_password("SFTP Password for " .. context.host .. ": ")
    auth = string.format("set sftp:password \"%s\";", password)
  end
  
  return string.format(
    "sftp://%s@%s:%d",
    context.username,
    context.host,
    context.port
  ), auth
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
      local conn_str, auth = build_connection_string(context)
      local remote_file = context.remotePath .. "/" .. relative_path
      
      local cmd = string.format(
        "lftp -u %s -e 'set sftp:auto-confirm yes; %s put %s -o %s; quit' %s",
        context.username,
        auth,
        current_file,
        remote_file,
        context.host
      )

      local result = vim.fn.system(cmd)
      if vim.v.shell_error ~= 0 then
        vim.notify("Upload failed: " .. result, vim.log.levels.ERROR)
      else
        vim.notify("Uploaded to " .. (context.name or context.host), vim.log.levels.INFO)
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
