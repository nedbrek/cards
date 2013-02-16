# client for playing card games, supports any number of players
package require Tk
package require crc32

source pcard.tcl

wm withdraw .
#####
set ::debug 0
set ::cardSetLoaded   0; # what cards are used
set ::cardSetLoadMenu 0; # gui display
set ::deckLoaded      0; # what subset is this player using
set ::deckLoadedMenu  0; # gui

set ::playerName "Ned"

set ::outConns ""; # outgoing network connections
set ::inConns  ""; # incoming network connections
# database of other players, indexed by channel
#set ::playerData($chn) "{playerList} other data list"

set ::netData ""

set ::ofileDir [pwd]; # remember directory for file io

set ::deck ""; # list of cards in order
#set ::cardData(cardName); # global card database

set ::cardsPlayed 0; # unique id for card widgets

### function library
# from http://wiki.tcl.tk/941
proc shuffle10a {l} {
   set len [llength $l]
   while {$len} {
      set n [expr {int($len*rand())}]
      set tmp [lindex $l $n]
      lset l $n [lindex $l [incr len -1]]
      lset l $len $tmp
   }
   return $l
}

# reflect message 't' to all channels, except 'chn' (where it came from)
proc netSend {t chn} {
   foreach c [concat $::outConns $::inConns] {
      if {$chn eq $c} { continue }
      puts -nonewline $c "$t\t"
      flush $c
   }
}

# update a read only log area
proc log {w t} {
   $w configure -state normal

   $w insert end $t
   $w see end

   $w configure -state disabled
}

###
proc announcePlayers {chn} {
   puts -nonewline $chn "[list name $::playerName]\t"

   foreach c [array names ::playerData] {
      foreach p $::playerData($c) {
         puts -nonewline $chn "[list name $p]\t"
      }
   }
   flush $chn
}

### file i/o
# parse a deck file (one or more "count{ \t}name\n")
proc loadDeck {} {
   set ofile [tk_getOpenFile -initialdir [file join $::ofileDir "decks"]]
   if {$ofile eq ""} { return }
   set ::ofileDir [removeDir [file dirname $ofile] "decks"]

   # side-out
   set ::deck ""

   set f       [open $ofile]
   set allData [read $f]
   set lData   [split $allData "\n"]

   # foreach line
   set lineno  0
   foreach e $lData {
      incr lineno
      if {$e eq ""} { continue }
      set e [string trim $e]

      set firstChar [string index $e 0]
      if {$firstChar eq "#"} { continue }

      set first2Chars [string range $e 0 1]
      if {$first2Chars eq "//"} { continue }

      set eData [split $e " \t"]
      set num   [lindex $eData 0]

      set cname [lrange $eData 1 end]
      if {![info exists ::cardData($cname)]} {
         tk_messageBox -message "Deck contains unknown card '$cname' (line $lineno)."
         continue
      }

      for {set i 0} {$i < $num} {incr i} {
         lappend ::deck $cname
      }
   }
   close $f

   set ::deckLoaded 1
   log .tGui.fBot.tComm "Deck $ofile loaded.\n"
}

proc removeDir {odir removePart} {
	set dirList [file split $odir]
	if {[lindex $dirList end] eq $removePart} {
		return [file join {*}[lrange $dirList 0 end-1]]
	}

	return [file join {*}$dirList]
}

proc loadCardSet {} {
   set ofile [tk_getOpenFile -initialdir [file join $::ofileDir "sets"]]
   if {$ofile eq ""} { return }
   set ::ofileDir [removeDir [file dirname $ofile] "sets"]

   if $::cardSetLoaded {
      # clean up current load
      unset ::cardData
   }

	set f   [open $ofile]
	set lines [split [read $f] \n]

	seek $f 0

   puts "Checksum [crc::crc32 -channel $f]"

	close $f

	foreach line $lines {
		set fields [split $line \t]
		set idx [lindex $fields 0]
		set ::cardData($idx) [lrange $fields 1 end]
	}

   set ::cardSetLoaded 1
   .mTopMenu.mFile entryconfigure 1 -state normal
   log .tGui.fBot.tComm "Cardset $ofile loaded\n"
}

proc processCmd {chn line} {
   set cmd [lindex $line 0]
   switch $cmd {
      draw    {
                 set name [lindex $line 1]
                 set num  [lindex $line 2]
                 log .tGui.fBot.tComm "$name draws $num card(s)\n"
              }

      move    {
                 set name  [lindex $line 1]
                 set id    [lindex $line 2]
                 set x     [lindex $line 3]
                 set y     [lindex $line 4]
                 set id $::cardIdMap($name,$id)
                 place .tGui.tCardDrag$id -x $x -y $y
              }

      name    {
                 set name [lindex $line 1]
                 lappend ::playerData($chn) $name
                 log .tGui.fBot.tComm "Welcome $name to the game.\n"
              }

      play    {
                 set name  [lindex $line 1]
                 set card  [lindex $line 2]
                 set style [lindex $line 3]
                 set x     [lindex $line 4]
                 set y     [lindex $line 5]
                 set id    [lindex $line 6]
                 log .tGui.fBot.tComm "$name plays $card $style\n"

                 set w ".tGui.tCardDrag$::cardsPlayed"
                 canvas $w -height 43 -width 40
                 paintCard $w [concat [list $card] $::cardData($card)]

                 set ::cardIdMap($name,$id) $::cardsPlayed

                 place $w -x $x -y $y
                 incr ::cardsPlayed
              }
      default {log .tGui.fBot.tComm "$line\n"}
   }
}

# data arrives from the network
proc netReadable {chn} {
   if [eof $chn] {
      log .tGui.fBot.tComm "Connection $chn closed\n"
      close $chn

      set i [lsearch $::outConns $chn]
      if {$i != -1} {
         lreplace $::outConns $i $i
      } else {
         set i [lsearch $::inConns $chn]
         if {$i != -1} {
            lreplace $::inConns $i $i
         } else {
            log .tGui.fBot.tComm "Error: Connection $chn not found!\n"
         }
      }
      return
   }

   # get the data from the network
   set rawData [read $chn]
log .tGui.fBot.tComm "Read '$rawData' from $chn\n"
   # reflect it
   netSend $rawData $chn

   # concat it into the command buffer
   append ::netData $rawData

   # process the command buffer (tab delimited commands)
   set i [string first "\t" $::netData]
   # while we have a tab in the buffer
   while {$i != -1} {
      # check for tab at start, not sure how that could happen...
      if {$i > 0} {
         # pull everything up to the tab (not including)
         set line [string range $::netData 0 [expr $i - 1]]
         processCmd $chn $line
      }

      # pinch off the processed data (and tab)
      set ::netData [string range $::netData [expr $i + 1] end]

      # back to top
      set i [string first "\t" $::netData]
   }
}

# server got a connection
proc getConn {chn addr port} {
   log .tGui.fBot.tComm "Received connection from $addr:$port\n"

   fconfigure $chn -blocking 0
   fileevent  $chn readable "netReadable $chn"

   lappend ::inConns $chn

   announcePlayers $chn
}

# user wants to stop listening
proc stopListen {} {
   close $::servSock
   unset ::servSock

   .tServCfg.bStart configure -text "Start" -command startListen
}

# user wants to start listening
proc startListen {} {
   set ::servSock [socket -server getConn $::listenPort]
   .tServCfg.bStart configure -text "Stop" -command stopListen
}

proc startRecv {} {
   set ::listenPort 4747

   if {![info  exists ::myIpAddr]} {
      proc tmpCmd {chn addr port} {
         close $chn
      }
      set tmpServ [socket -server tmpCmd 0]
		set cname "127.0.0.1"
		if {[array names env COMPUTERNAME] ne ""} {
			set cname $::env(COMPUTERNAME)
		}
      set tmpSock [socket $cname [lindex [fconfigure $tmpServ -sockname] 2]]
      set ::myIpAddr [lindex [fconfigure $tmpSock -sockname] 0]
      close $tmpSock
      close $tmpServ
   }

   if {![winfo exists .tServCfg]} {
      toplevel .tServCfg
      wm title .tServCfg "Receive Call"
      bind .tServCfg <Destroy> {
         if [info exists ::servSock] {
            close $::servSock
            unset ::servSock
         }
      }

      pack [label .tServCfg.lIP -text "My address: $::myIpAddr"] -side top
      pack [frame .tServCfg.fPort] -side top
      pack [label .tServCfg.fPort.l -text "Use port:"] -side left
      pack [entry .tServCfg.fPort.e -textvariable ::listenPort] -side right

      pack [button .tServCfg.bStart -text "Start" -command startListen] -side top
   }
}

# start client conn
proc startCall {} {
   set chn [socket -async $::sendAddr $::sendPort]
   fconfigure $chn -blocking 0
   fileevent  $chn readable "netReadable $chn"

   lappend ::outConns $chn
   log .tGui.fBot.tComm "Made connection to $::sendAddr:$::sendPort\n"
   announcePlayers $chn
}

# build the dialog to start a client conn
proc sendCall {} {
   if [winfo exists .tCallCfg] { return }

   toplevel .tCallCfg
   wm title .tCallCfg "Send Call"

   pack [frame .tCallCfg.fIP] -side top
   pack [label .tCallCfg.fIP.lIP -text "Address:"] -side top
   pack [entry .tCallCfg.fIP.e -textvariable ::sendAddr] -side right
   pack [frame .tCallCfg.fPort] -side top
   pack [label .tCallCfg.fPort.l -text "Port:"] -side left
   pack [entry .tCallCfg.fPort.e -textvariable ::sendPort] -side right

   pack [button .tCallCfg.bStart -text "Start" -command startCall] -side top
}

#####
proc chooseNameOk {} {
   set ::playerName [.tSetName.f1.e get]
   destroy .tSetName
}

proc chooseName {} {
   toplevel .tSetName
   wm title .tSetName "Set Name"
   pack [frame .tSetName.f1] -side top
   pack [label .tSetName.f1.l -text "Enter your name:"] -side left
   pack [entry .tSetName.f1.e] -side left
   .tSetName.f1.e insert 0 $::playerName
   .tSetName.f1.e selection range 0 end
   focus .tSetName.f1.e

   bind .tSetName <Return> chooseNameOk
   bind .tSetName <Escape> "destroy .tSetName"

   pack [frame  .tSetName.f2] -side top
   pack [button .tSetName.f2.bOk -text "Ok" -command chooseNameOk -default active] -side left
   pack [button .tSetName.f2.bCl -text "Cancel" -command "destroy .tSetName"] -side left
}

#####
proc drawCard {} {
   set ret [lindex $::deck 0]

   set ::deck [lreplace $::deck 0 0]

   return $ret
}

proc menuDrawCard {} {
   set card [drawCard]
   .tGui.fLeft.lbHand insert end $card
   log .tGui.fBot.tComm "$::playerName draws a card.\n"
   netSend "draw $::playerName 1" ""
}

proc menuShuffle {} {
   set ::deck [shuffle10a $::deck]
   log .tGui.fBot.tComm "$::playerName shuffles his deck.\n"
   netSend "$::playerName shuffles his deck." ""
}

proc playCard {i style x y id} {
   bind .tGui <Motion> ""
   bind .tGui <ButtonRelease-1> ""

   set name [.tGui.fLeft.lbHand get $i]
   .tGui.fLeft.lbHand delete $i

   log .tGui.fBot.tComm "$::playerName plays $name $style.\n"

   netSend [list play $::playerName $name $style $x $y $id] ""
}

proc startCardHandDrag {y mode} {
   set i [.tGui.fLeft.lbHand nearest $y]
   if {$i eq ""} { return }
   set name [.tGui.fLeft.lbHand get $i]
   if {$name eq ""} { return }

   canvas .tGui.tCardDrag$::cardsPlayed -height 43 -width 40

   paintCard .tGui.tCardDrag$::cardsPlayed [concat [list $name] $::cardData($name)]

   set w ".tGui.tCardDrag$::cardsPlayed"
   bind .tGui <Motion> \
"place $w -x \[expr %x - 12\] -y \[expr %y -12\]"
   bind $w <1> "startCardPlayDrag %W %x %y"

   bind .tGui <ButtonRelease-1> [list playCard $i $mode %x %y $::cardsPlayed]

   incr ::cardsPlayed
}

proc moveCard {w x y} {
   bind .tGui <Motion> ""
   bind .tGui <ButtonRelease-1> ""

   #Ned, check for removing card from play...

   set x [expr $x - [winfo rootx .tGui]]
   set y [expr $y - [winfo rooty .tGui]]
   puts "Moved card $w to $x $y"

   set id [regsub ".tGui.tCardDrag" $w ""]
   netSend [list move $::playerName $id $x $y] ""
}

proc startCardPlayDrag {w x y} {
   set xoff [expr [winfo rootx .tGui] + $x]
   set yoff [expr [winfo rooty .tGui] + $y]

   bind .tGui <Motion> \
"place $w -x \[expr %X - $xoff\] -y \[expr %Y - $yoff\]"

   bind .tGui <ButtonRelease-1> [list moveCard $w %X %Y]
}

if 0 {
}

#####
toplevel    .tGui
wm title    .tGui "Card Game Client"
pack [frame .tGui.secretFrame]
bind .tGui.secretFrame <Destroy> { exit }
wm geometry .tGui 840x680

pack [frame   .tGui.fLeft] -side left -expand 1 -fill y -anchor w
pack [listbox .tGui.fLeft.lbHand] -side left -expand 1 -fill y

pack [frame .tGui.fBot] -side bottom -expand 1 -fill x -anchor sw
pack [text  .tGui.fBot.tComm -state disabled -width 117 -height 12] \
    -side left -expand 1 -fill x -anchor sw

# top menu build
menu .mTopMenu          -tearoff 0
menu .mTopMenu.mFile    -tearoff 0
menu .mTopMenu.mNetwork -tearoff 0
menu .mTopMenu.mAction  -tearoff 0
menu .mTopMenu.mOption  -tearoff 0

# top menu construct
.mTopMenu add cascade -label "File"    -menu .mTopMenu.mFile    -underline 0
.mTopMenu add cascade -label "Network" -menu .mTopMenu.mNetwork -underline 0
.mTopMenu add cascade -label "Action"  -menu .mTopMenu.mAction  -underline 0
.mTopMenu add cascade -label "Option"  -menu .mTopMenu.mOption  -underline 0

# file menu
.mTopMenu.mFile add radiobutton -label "Load Card Set" -command loadCardSet \
    -underline 5 -value 1 -variable cardSetLoadMenu
.mTopMenu.mFile add radiobutton -label "Load Deck" -command loadDeck \
    -underline 5 -value 1 -variable deckLoadedMenu -state disabled
.mTopMenu.mFile add command -label "Exit" -command exit -underline 1 -accelerator "Ctrl+Q"

# network menu
.mTopMenu.mNetwork add command -label "Receive Call" -command startRecv -underline 0
.mTopMenu.mNetwork add command -label "Send Call"    -command sendCall  -underline 0

# action menu
.mTopMenu.mAction add command -label "Draw Card" -command menuDrawCard -underline 0 -accelerator "Ctrl+D"
.mTopMenu.mAction add command -label "Shuffle"   -command menuShuffle  -underline 0 -accelerator "Ctrl+S"

# option menu
.mTopMenu.mOption add command -label "Set Name" -command chooseName -underline 0

#####
.tGui configure -menu .mTopMenu

### bindings
bind .tGui <Control-q> exit
bind .tGui <Control-d> menuDrawCard
bind .tGui <Control-s> menuShuffle

bind .tGui.fLeft.lbHand <1>               "startCardHandDrag %y normal"
bind .tGui.fLeft.lbHand <Shift-1>         "startCardHandDrag %y facedown"
bind .tGui.fLeft.lbHand <Control-1>       "startCardHandDrag %y tapped"
bind .tGui.fLeft.lbHand <Control-Shift-1> [list startCardHandDrag %y [list tapped facedown]]

