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
  
  return vim.json.decode(content)
end

return M
