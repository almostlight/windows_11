#Requires AutoHotkey v2.0

toggle := false

^!Enter:: {
    global toggle
    toggle := !toggle
    
    if (toggle) {
        SetTimer(SendClickAndEnter, 50)
        ToolTip("Loop ON: Sending Left Click + Enter every 50ms", 10, 10)
        A_KeyDelay := 50
    } else {
        SetTimer(SendClickAndEnter, 0)
        ToolTip()
    }
}

SendClickAndEnter() {
    Send("{LButton}")
    Sleep(10)
    Send("{Enter}")
}

^!Esc:: {
    global toggle
    toggle := false
    SetTimer(SendClickAndEnter, 0)
    ToolTip()
}
