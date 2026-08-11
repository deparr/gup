# gup

A small Godot version manager and download helper.

Primary use case is downloading official binaries and storing them in `~/.local/bin`; optionally creating symlinks to easily launch specific builds.

gup can also install Godot in [self-contained mode](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html#self-contained-mode), allowing you to make project specific installations.

> [!NOTE]
> gup defaults are based on how I like to install and use Godot. 

```sh
zig build
./zig-out/bin/gup help
```


### usage
```
$ gup install 4.8-dev3 --link-name=godot-dev --dir=v:/.local/bin/

info(fetch): fetching remote: https://downloads.godotengine.org?version=4.8&flavor=dev3&slug=win64.exe.zip&platform=windows.64
info(install): extracting to v:/.local/bin/
info(install): extracting Godot_v4.8-dev3_win64.exe
info(install): extracting Godot_v4.8-dev3_win64_console.exe
info(install): symlinked binaries to godot-dev

$ godot-dev
```

```
$ gup install 4.7.1 --script=dotnet --link-name=godot-mono --dir=v:/.local/bin/
info(fetch): fetching remote: https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_mono_win64.zip
info(install): extracting to v:/.local/bin/
info(install): symlinked binaries to godot-mono

$ godot-mono_console
```

```
$ gup cache list
gup cache 'C:\Users\Dpar\AppData\Local\gup':
  4.6.2-stable/      76M
  ├ sha512-sums.txt  4K
  └ win64.exe.zip    76M

  4.7.1-stable/      189M
  ├ mono_win64.zip   109M
  ├ sha512-sums.txt  5K
  └ win64.exe.zip    80M

  4.8-dev3/          189M
  ├ mono_win64.zip   109M
  ├ sha512-sums.txt  0B
  └ win64.exe.zip    80M

total_size: 455M
```
