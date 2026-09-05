+++
type = "docs"
title = "Installation"
weight = 1
+++


Larecs🌲 is written in and for [Mojo](https://docs.modular.com/mojo/manual/get-started)🔥, which needs to be installed in order to compile, test, or use the software. You can build Larecs🌲 as a package as follows:

1. Clone the repository / download the files.
2. Navigate to the `src/` subfolder.
3. Execute `mojo precompile larecs -o larecs.mojoc`.
4. Move the newly created file `larecs.mojoc` to your project's source directory.

## Include the source directly when compiling

Instead of building Larecs🌲 as a package, you can also include its
source code directly when running or compiling your own project.
This has the advantage that you can access the source while debugging 
and adjusting the Larecs🌲 source code. 
You can include the Larecs🌲 source code as follows:

```
mojo run -I "path/to/larecs/src" example.mojo
```

## Include Larecs🌲 in VSCode and its language server

To let VSCode and its language server know of Larecs🌲 
(so that Ctrl-Click, mouse hover docs, autocomplete
and error checking are available), include the package as follows:

1. Go to VSCode's `File -> Preferences -> Settings` page.
2. Go to the `Extensions -> Mojo` section.
3. Look for the setting `Lsp: Include Dirs`.
4. Click on `add item` and insert the path to the `src/` subdirectory.
