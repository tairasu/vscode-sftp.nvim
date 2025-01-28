local M = {}

function M.find_config()
  -- Search upward for .vscode/sftp.json
  local current_file = vim.fn.expand("%:p")
  local current_dir = vim.fn.fnamemodify(current_file, ":h")
  
  return vim.loop.fs_realpath(
    vim.fn.findfile(".vscode/sftp.json", current_dir .. ";")
  )
end

function M.parse_config(path)
  local file = io.open(path, "r")
  if not file then return nil end
  
  local content = file:read("*a")
  file:close()
  
  local conf = vim.json.decode(content)
  
  -- Normalize config structure for single/multiple contexts
  if not conf.contexts then
    conf.contexts = {conf} -- Treat root config as single context
  end
  
  -- Add default values
  for _, ctx in ipairs(conf.contexts) do
    ctx.protocol = ctx.protocol or "sftp"
    ctx.port = ctx.port or 22
    ctx.uploadOnSave = ctx.uploadOnSave or false
    -- Don't store password in config file
    ctx.password = nil
  end
  
  return conf
end

return M
