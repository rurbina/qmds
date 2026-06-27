# QMDS

QMDS: Quick Markdown Server, very simple content management using Markdown.

It's a PSGI app meant to be used behind Nginx. It takes a folder with Markdown files and serves them as HTML. It works with CommonMark with a few extensions

## Thin framework

You can provide a custom controller and use it to create web apps. It provides a few basic functions such as parsing params and session control, you just pop in your controller and templates in template toolkit + markdown.

## Obsidian

I edit my files with [Obsidian](https://obsidian.md), so there's a certain amount of compatibility with it.

