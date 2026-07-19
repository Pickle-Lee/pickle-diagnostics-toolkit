Output demo.gif
Set Shell bash
Set FontSize 16
Set Width 1360
Set Height 430
Set Padding 22
Set Theme "Dracula"
Set TypingSpeed 55ms

Hide
Type "cp verdict.sh /tmp/powershell && chmod +x /tmp/powershell && export PATH=/tmp:$PATH && export PS1='PS C:\\tools> ' && clear"
Enter
Show

Sleep 700ms
Type "powershell -NoProfile -File .\diagnostic.ps1 -Quiet -ConfigPath config.json"
Sleep 500ms
Enter
Sleep 3s
