local M = {}

-- Define highlight groups
local function setup_highlights()
  vim.api.nvim_set_hl(0, 'FileBrowserBlue', { fg = '#569CD6' })
  vim.api.nvim_set_hl(0, 'FileBrowserYellow', { fg = '#DCDCAA' })
  vim.api.nvim_set_hl(0, 'FileBrowserGreen', { fg = '#608B4E' })
  vim.api.nvim_set_hl(0, 'FileBrowserRed', { fg = '#F44747' })
  vim.api.nvim_set_hl(0, 'FileBrowserGray', { fg = '#858585' })
  vim.api.nvim_set_hl(0, 'FileBrowserBold', { bold = true })
end

-- Initialize highlights
setup_highlights()

-- Format file size with appropriate units
local function format_size(size)
  if size == 0 then
    return { text = "0 bytes", hl = 'FileBrowserGray' }
  end

  local units = { "bytes", "KB", "MB", "GB" }
  local unit_index = 1
  local display_size = size

  while display_size >= 1024 and unit_index < #units do
    display_size = display_size / 1024
    unit_index = unit_index + 1
  end

  if unit_index == 1 then
    return { text = string.format("%d %s", display_size, units[unit_index]), hl = 'FileBrowserBlue' }
  else
    return { text = string.format("%.2f %s", display_size, units[unit_index]), hl = 'FileBrowserBlue' }
  end
end

-- Format size difference with colors and symbols
function M.format_size_diff(new_size, old_size)
  local diff = new_size - old_size
  if diff == 0 then
    return { text = "±0 bytes", hl = 'FileBrowserGray' }
  end

  local sign = diff > 0 and "+" or "-"
  local color = diff > 0 and 'FileBrowserGreen' or 'FileBrowserRed'
  local abs_diff = math.abs(diff)

  local units = { "bytes", "KB", "MB", "GB" }
  local unit_index = 1
  local display_size = abs_diff

  while display_size >= 1024 and unit_index < #units do
    display_size = display_size / 1024
    unit_index = unit_index + 1
  end

  if unit_index == 1 then
    return { text = string.format("%s%d %s", sign, display_size, units[unit_index]), hl = color }
  else
    return { text = string.format("%s%.2f %s", sign, display_size, units[unit_index]), hl = color }
  end
end

-- Format timestamp in a consistent way
function M.format_timestamp(timestamp)
  if timestamp == 0 then
    return { text = "Never", hl = 'FileBrowserGray' }
  end
  return { text = os.date("%Y-%m-%d %H:%M:%S", timestamp), hl = 'FileBrowserYellow' }
end

-- Create summary header for file list
function M.create_summary_header(files_count, total_size)
  local total_size_str = format_size(total_size)
  local header = string.format("\n %s%d files to process (Total size: %s)\n",
    vim.fn.strtrans('FileBrowserBold'),
    files_count,
    total_size_str.text
  )

  -- Add column headers with proper spacing and alignment
  header = header .. "\n"
  header = header .. string.format(" %-50s  %-25s  %-20s  %-30s\n",
    "File Name",
    "Modified Date",
    "Size",
    "Status"
  )

  -- Add separator line with proper width
  header = header .. " " .. string.rep("─", 128) .. "\n"

  return { text = header, hl = 'FileBrowserBold' }
end

-- Format file list item for display
function M.format_list_item(file)
  local status
  if file.local_mtime == 0 then
    status = { text = "(New File)", hl = 'FileBrowserGreen' }
  else
    local size_diff = M.format_size_diff(file.info.size, file.local_size)
    status = { text = string.format("(Update: %s)", size_diff.text), hl = size_diff.hl }
  end

  local name = string.format("%-50s", file.name:sub(1, 47) .. (file.name:len() > 47 and "..." or ""))
  local date = M.format_timestamp(file.info.mtime)
  local size = format_size(file.info.size)

  return {
    text = string.format(" %-50s  %-25s  %-20s  %-30s", name, date.text, size.text, status.text),
    highlights = {
      { hl_group = 'FileBrowserBlue', from = 0, to = 50 },
      { hl_group = date.hl, from = 52, to = 77 },
      { hl_group = size.hl, from = 79, to = 99 },
      { hl_group = status.hl, from = 101, to = -1 }
    }
  }
end

-- Show file list in a floating window
function M.show_file_list(files, total_size)
  local lines = {}
  local max_width = 0

  -- Add header
  local header = M.create_summary_header(#files, total_size)
  table.insert(lines, { text = header.text, hl = header.hl })

  -- Format file items
  for _, file in ipairs(files) do
    local item = M.format_list_item(file)
    table.insert(lines, item)
    max_width = math.max(max_width, vim.fn.strdisplaywidth(item.text))
  end

  -- Create buffer and window
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(max_width + 4, vim.o.columns - 4)  -- 4 = padding
  local height = math.min(#lines + 2, vim.o.lines - 4)      -- 2 = margin

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = 'minimal',
    border = 'rounded'
  })

  -- Add content with highlights
  local ns = vim.api.nvim_create_namespace('FileBrowserHL')
  for i, line in ipairs(lines) do
    vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { line.text })
    if line.highlights then
      for _, hl in ipairs(line.highlights) do
        vim.api.nvim_buf_add_highlight(buf, ns, hl.hl_group, i - 1, hl.from, hl.to)
      end
    end
  end
end

-- Show error message
function M.show_error(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "File Browser Error" })
end

-- Show success message
function M.show_success(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "File Browser Success" })
end

-- Show info message
function M.show_info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "File Browser Info" })
end

-- Show warning message
function M.show_warning(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "File Browser Warning" })
end

return M