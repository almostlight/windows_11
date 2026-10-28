#Requires AutoHotkey v2.0
#SingleInstance
#Warn All, Off

; Turn capslk into another esc
CapsLock::Send "{Esc}"
; Toggle caps with shift+capslk
+CapsLock::SetCapsLockState !GetKeyState("CapsLock", "T")

#Enter::Run "wt.exe"
#+Enter::Run "pwsh.exe"
; #e::Run "files:"
#e::Run "explorer.exe"
#v::Send "#v"
#q::Send "!{F4}"
<^<!Up::Send "{Volume_Mute}"
<^<!Down::Send "{Media_Play_Pause}"
<^<!Left::Send "{Media_Prev}"
<^<!Right::Send "{Media_Next}"

;======================
; More complex scripts
;======================

; Extract archive using 7-Zip CLI
#+a::{
    try {
        selected := ""
        shell := ComObject("Shell.Application")

        ; Get the first selected item from the active Explorer window.
        for explorer in shell.Windows {
            try {
                if (explorer.HWND = WinExist("A") && explorer.Document.SelectedItems.Count > 0) 
                    selected := explorer.Document.SelectedItems.Item(0).Path
                    break
                }
            }

        if (!selected) {
            for explorer in shell.Windows {
                try {
                    if (explorer.Document.SelectedItems.Count > 0) {
                        selected := explorer.Document.SelectedItems.Item(0).Path
                        break
                    }
                }
            }
        }

        zipPath := "C:\Program Files\7-Zip\7z.exe"

        if (!FileExist(zipPath)) {
            MsgBox("7-Zip not found at: `n`n" zipPath "`n`nPlease update the path in the script.", "Extract", 0x40010)
            return
        }

        if (!selected) {
            MsgBox("No selected archive found in Explorer.", "Extract", 0x40010)
            return
        }

        SplitPath(selected, &fileName, &directory, &extension, &baseName)
        if (!baseName) {
            MsgBox("The selected item does not have a valid file name.", "Extract", 0x40010)
            return
        }

        extractTo := directory "\" baseName "_extracted"
        command := Format('"{}" x "{}" -o"{}" -aoa -y', zipPath, selected, extractTo)
        exitCode := RunWait(command, , "Hide")

        if (exitCode != 0) {
            MsgBox("7-Zip failed with exit code " exitCode ".", "Extract", 0x40010)
            return
        }

        MsgBox("Extracted to: `n`n" extractTo, "Extract Complete", 0x40000)
    } catch as e {
        MsgBox("Error: " e.Message, "Extract", 0x40010)
    }
}
