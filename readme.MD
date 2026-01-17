# Huginn

A simple TUI Arch User Repository (AUR) interactive search tool built in `Odin` on top of `paru`.

![screenshot](./screenshot.png)

> requires paru to run [link](https://github.com/Morganamilo/paru)

# Installation

## From source

Prerequisites: 
- `paru` [link](https://github.com/Morganamilo/paru)
- `odin` [link](https://odin-lang.org/docs/install/)

```bash
git clone https://github.com/krisfur/huginn.git
cd huginn
odin build .
```

then you can simply run the resulting executable

```bash
./huginn
```

to add it to make it callable from anywhere simple copy it to your local bin folder like:

```bash
sudo cp huginn /usr/local/bin/huginn
```

## tl;dr give me the full commands (from source)

paru:
```bash
sudo pacman -S --needed base-devel
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si
```
odin:
```bash
paru -S odin-git
```
huginn:
```bash
git clone https://github.com/krisfur/huginn.git
cd huginn
odin build .
sudo cp huginn /usr/local/bin/huginn
```
