#!/var/jb/usr/bin/bash
# After the jailbreak (userland/jb/sweet_jbinstall.c) is in place: run once by libsweet-fix in configd through the
# run file (/private/var/sweet-metal/run, tools/root-files/jb-post.txt), as root. Lines go to
# /private/var/sweet-jb/install.log, whose end libsweet-fix copies into the kernel log at every boot ("sweet-jb post:").
#
#  1. Sileo lives in /Applications since boot 109 (sileo-system.txt: lsd registers only what it finds there itself).
#     dpkg still lists its files under /var/jb/Applications/Sileo.app: a link from there to /Applications/Sileo.app
#     makes a Sileo update land in the registered copy instead of a second, unregistered one.
#  2. Apps: every /private/var/sweet-jb/apps/*.tar.gz (made on the PC by tools/app-pack.sh from an .ipa or .app) is
#     unpacked into /Applications and removed. They show up once LaunchServices reseeds: boot once more with
#     tools/root-files/ls-rebuild.txt (the store is removed by the kernel before lsd starts; removing it here, under
#     a running lsd, would not stick).
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
LOG=/private/var/sweet-jb/install.log
say() { echo "sweet-jb post: $*" >> "$LOG"; }

say "start ($(date 2>/dev/null))"
if [ -d /Applications/Sileo.app ] && [ ! -e /var/jb/Applications/Sileo.app ] && [ ! -L /var/jb/Applications/Sileo.app ]; then
	mkdir -p /var/jb/Applications && ln -s /Applications/Sileo.app /var/jb/Applications/Sileo.app &&
		say "Sileo: /var/jb/Applications/Sileo.app -> /Applications/Sileo.app" || say "Sileo: the link FAILED"
elif [ -L /var/jb/Applications/Sileo.app ]; then
	say "Sileo: already linked"
else
	say "Sileo: not moved to /Applications (or a copy is in /var/jb): left alone"
fi

new=0
for a in /private/var/sweet-jb/apps/*.tar.gz; do
	[ -e "$a" ] || continue
	names=$(tar -tzf "$a" 2>/dev/null | sed -n 's|^\(\./\)\{0,1\}\([^/]*\.app\)/.*|\2|p' | sort -u)
	if [ -z "$names" ] || [ "$(echo "$names" | wc -l)" -ne 1 ]; then
		say "$a: not one .app at its top: skipped"
		continue
	fi
	if tar -xzf "$a" -C /Applications --no-same-owner 2>>"$LOG"; then
		chown -R 0:0 "/Applications/$names" 2>/dev/null
		chmod -R go-w "/Applications/$names" 2>/dev/null
		say "$a: /Applications/$names unpacked"
		rm -f "$a"
		new=$((new + 1))
	else
		say "$a: unpacking FAILED"
	fi
done
[ "$new" -gt 0 ] && say "$new app(s) unpacked: boot once with tools/root-files/ls-rebuild.txt to see them"
say "done"
