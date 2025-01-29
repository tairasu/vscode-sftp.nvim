# vscode-sftp.nvim

> [!NOTE]  
> Very early development. Expect some things to not work.

A Neovim plugin that brings VS Code's SFTP functionality to Neovim. This plugin allows you to automatically sync your local workspace with a remote server through SFTP/FTP.

## Features

- 📁 Sync local workspace with remote server
- 💾 Auto upload on save
- 🔄 Bidirectional synchronization
- 🔐 Secure SFTP connections
- ⚡ Multiple profile support
- 🌐 Support for connection hopping (proxy)
- 📝 Simple configuration through `sftp.json`

## Requirements

- Neovim >= 0.8.0
- `plenary.nvim` (for async operations and utilities)
- `ssh.nvim` (for SFTP operations)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    'tairasu/vscode-sftp.nvim',
    dependencies = {
        'nvim-lua/plenary.nvim',
        'miversen33/ssh.nvim'
    },
    config = true
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
    'tairasu/vscode-sftp.nvim',
    requires = {
        'nvim-lua/plenary.nvim',
        'miversen33/ssh.nvim'
    }
}
```

## Configuration

1. Create an `sftp.json` file in your project's `.vscode` directory:

```json
{
    "name": "My Server",
    "host": "hostname",
    "protocol": "sftp",
    "port": 22,
    "username": "username",
    "remotePath": "/path/to/remote/project",
    "uploadOnSave": true,
    "privateKeyPath": "~/.ssh/id_rsa",
    "ignore": [
        ".vscode",
        ".git",
        ".DS_Store",
        "node_modules",
        "dist"
    ]
}
```

2. (Optional) Configure the plugin in your Neovim config:

```lua
require('vscode-sftp').setup({
    -- Optional configuration options
    auto_upload = true,  -- Enable/disable auto upload on save
    debug = false,       -- Enable debug logging
})
```

## Usage

The plugin provides the following commands:

- `:SFTPUpload` - Upload the current file
- `:SFTPDownload` - Download the current file
- `:SFTPSync` - Sync the entire project
- `:SFTPInit` - Create a new sftp.json configuration file
- `:SFTPDelete` - Delete remote file/directory

## License

MIT

## Credits

This plugin is inspired by the [VS Code SFTP extension](https://github.com/Natizyskunk/vscode-sftp).
