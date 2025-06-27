# better-git-blame
a lazy nvim plugin created to add more functionality to a git blame directly within nvim by gathering all commits that changed the selected lines and allowing the user to see the diff of those commits

the idea behind this plugin was to offer a better history of a specific block of code, such as a method or class. a drawback of this approach is that the block of code will end up on multiple sets of lines through development as things are added and removed and i have not thought of a workaround for that.

open to ideas. may be possible to select git commits in the file that contain portions of selected text but that does complicate it

## Features
* Analyze Git history (`git log -L`) for lines visually selected
* Present relevant commits in telescope picker with preview showing changes
* `<CR>` a commit to open a full diff view of the selected commit (vim-fugitive or diffview.nvim if available)
## Use
### `:BlameInvestigate`
* Visually select lines of code to search for git commits that have affected one or more of the selected line numbers
* Heuristic as same code may not be on same lines as development progresses
### `:BlameInvestigateContent`
* Visually select lines of code, the function will find the longest line in selection and run a posix-ere escape function to prepare it for a regex search with git log -G
* Longest line of may not be code or unique so could get false positives
* Would like to apply a fuzzy search which may allow searching with multiple lines
### `:BlameShowLast`
* Running the investigate commands caches the information used so running `:BlameShowLast` will open a telescope picker using the same commit list that was found with the investigate command
* Only stores last search
## Setup
### Dependencies
* Neovim (developed on v0.10.4)
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
        "nvim-lua/plenary.nvim",
        "nvim-telescope/telescope.nvim",
        -- Optional but highly recommended
        -- "tpope/vim-fugitive"
        -- "sindrets/diffview.nvim"
    },

    config = function()
        require("better-git-blame").setup({
            -- calling setup alone will setup the BlameInvestigate, BlameInvestigateContent, and BlameShowLast commands
        })
    end,
}
```
