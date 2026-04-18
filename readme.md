# gup

**very wip** utility to manage godot engine versions


```sh
zig build
./zig-out/bin/gup --help
```

```
$ gup --version=4.7 --flavor=dev5 --setup-links=1 --install-path=v:/.local/bin/

info(gup): attempting to fetch uri: https://downloads.godotengine.org/?version=4.7&flavor=dev5&slug=win64.exe.zip&platform=windows.64
info(gup): zip_bytes len: 80644414
info(gup): extracting to v:/.local/bin
info(gup): extracting Godot_v4.7-dev5_win64.exe
info(gup): extracting Godot_v4.7-dev5_win64_console.exe
```
