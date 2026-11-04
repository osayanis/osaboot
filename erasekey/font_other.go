//go:build !linux

package main

// Hors Linux (aperçus sur Mac), pas de console à agrandir.
func BiggerFont(fd int) bool { return false }
