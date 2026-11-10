-- Start only the supplied private worker in a newly observed Terminal tab.
on run argv
	if (count of argv) is not 1 then error "A single resume worker path is required."
	set workerPath to item 1 of argv
	if application id "com.apple.Terminal" is not running then error "Open a Terminal window before approving the batch."
	tell application id "com.apple.Terminal"
		if (count of windows) is 0 then error "Open a Terminal window before approving the batch."
		set originalWindow to id of front window
		set previousTtys to tty of every tab of front window
		activate
	end tell
	tell application id "com.apple.systemevents"
		if UI elements enabled is false then error "Terminal tab creation is unavailable."
		tell process "Terminal"
			if frontmost is false then error "Terminal did not become the active application."
			keystroke "t" using {command down}
		end tell
	end tell
	repeat 30 times
		delay 0.1
		tell application id "com.apple.Terminal"
			if not (exists window id originalWindow) then error "The target Terminal window changed."
			set targetWindow to window id originalWindow
			set currentTtys to tty of every tab of targetWindow
			set newTtys to {}
			repeat with oneTty in currentTtys
				set ttyPath to contents of oneTty
				if ttyPath is not in previousTtys and ttyPath starts with "/dev/tty" then set end of newTtys to ttyPath
			end repeat
			if (count of currentTtys) > ((count of previousTtys) + 1) or (count of newTtys) > 1 then error "The new Terminal tab is ambiguous."
			if (count of currentTtys) is ((count of previousTtys) + 1) and (count of newTtys) is 1 then
				set observedTty to item 1 of newTtys
				if (tty of selected tab of targetWindow) is not observedTty then error "The new Terminal tab is not selected."
				do script ("exec /bin/zsh -f " & quoted form of workerPath) in (first tab of targetWindow whose tty is observedTty)
				return "accepted " & observedTty
			end if
		end tell
	end repeat
	error "No new Terminal tab could be verified."
end run
