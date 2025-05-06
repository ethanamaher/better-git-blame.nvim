# better-git-blame
a lazy nvim plugin created to add more functionality to a git blame directly within nvim by gathering all commits that changed the selected lines and allowing the user to see the diff of those commits

## Features
* Analyze Git history (`git log -L`) for lines visually selected
* Present relevant commits in telescope picker with preview showing changes
* `<CR>` a commit to open a full diff view of the selected commit (vim-fugitive or diffview.nvim if available)

## Setup
### Dependencies
* Neovim 0.9.5+
* telescope.nvim
* plenary.nvim
* **Optional**
    * vim-fugitive **(highly recommended)**
    * diffview.nvim
### Installation
Add the following to your `lazy.nvim` plugin configuration
```lua
return {
    "ethanamaher/better-git-blame.nvim",

    dependencies = {
        "nvim-lua-plenary/nvim",
        "nvim-telescope/telescope.nvim",
        -- Optional but highly recommended
        -- "tpope/vim-fugitive"
        -- "sindrets/diffview.nvim"
    
    },

    config = function()
        require("better-git-blame").setup({
            -- calling setup alone will setup the BlameInvestigate command used to preview git history
            -- may add future configuration options
        })
    end,
}
```
