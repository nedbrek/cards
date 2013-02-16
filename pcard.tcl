set cardTxtFont [font create -size 7]

proc paintCard {c data} {
   set name  [lindex $data 0]
   $c configure -background white
   $c create text 2 2 -text $name -anchor nw -width 38 -fill black -font $::cardTxtFont
}

