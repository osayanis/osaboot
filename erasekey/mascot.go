package main

import "strings"

// La mascotte OsaLabs, en caractères pleins (la console Linux sait les dessiner).
// Le corps est plein, les yeux et la bouche sont des trous.

type Mood int

const (
	Calm Mood = iota
	Happy
	Worried
	Busy
)

// frame : numéro d'image (clignement, bras qui bougent).
// Les trous font 1 caractère de large : dans la police de la console, deux trous voisins se
// touchent et le visage devient illisible.
func Mascot(m Mood, frame int) string {
	blink := frame%23 == 0 && m != Busy
	eyes := []string{"████ ██ ████", "████ ██ ████"}
	switch {
	case blink:
		eyes = []string{"████████████", "████▀██▀████"}
	case m == Happy:
		eyes = []string{"████▄██▄████", "████████████"}
	case m == Busy:
		eyes = []string{"█████ ██ ███", "█████ ██ ███"}
	case m == Worried:
		eyes = []string{"███▄████▄███", "████ ██ ████"}
	}
	mouth := []string{"████▀▀▀▀████", "▀██████████▀"}
	switch m {
	case Happy:
		mouth = []string{"███▄▀▀▀▀▄███", "▀██████████▀"}
	case Worried:
		mouth = []string{"███▀▄▄▄▄▀███", "▀██████████▀"}
	case Busy:
		mouth = []string{"██████▀▀████", "▀██████████▀"}
	}
	rows := []string{"  ▄██████▄  ", "████████████", eyes[0], eyes[1], mouth[0], mouth[1], "   ▀▀  ▀▀   "}

	left, right := " ", " "
	armRow := 3
	switch m {
	case Happy:
		left, right = "▀", "▀"
		armRow = 1
		if frame%4 < 2 {
			armRow = 2
		}
	case Busy:
		if frame%2 == 0 {
			left, right = "▄", "▀"
		} else {
			left, right = "▀", "▄"
		}
	default:
		left, right = "▄", "▄"
	}
	for i := range rows {
		l, r := "  ", "  "
		if i == armRow {
			l, r = left+" ", " "+right
		}
		rows[i] = l + rows[i] + r
	}
	return strings.Join(rows, "\n")
}
