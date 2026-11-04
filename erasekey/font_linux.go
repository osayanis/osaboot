//go:build linux

package main

import (
	"syscall"
	"unsafe"
)

// Police deux fois plus grosse sur les écrans haute définition.
//
// La console Linux garde sa petite police 8×16 quelle que soit la définition : sur un écran
// 1920×1080, le texte est minuscule. On lit la police du terminal, on double chaque pixel
// (8×16 → 16×32) et on la remet, seulement si l'interface tient encore à l'écran.
// Rien n'est installé : c'est réglé pour cette console, jusqu'au prochain démarrage.

const (
	kdFontOp      = 0x4B72 // KDFONTOP
	kdFontOpSet   = 0
	kdFontOpGet   = 1
	fontVPitch    = 32 // le noyau range chaque caractère sur 32 lignes
	minColsBigger = 96
	minRowsBigger = 28
)

type consoleFontOp struct {
	Op, Flags, Width, Height, Charcount uint32
	Data                                uintptr
}

type winsize struct{ Rows, Cols, X, Y uint16 }

func ioctl(fd int, req uintptr, arg unsafe.Pointer) error {
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), req, uintptr(arg)); e != 0 {
		return e
	}
	return nil
}

// BiggerFont double la police de la console fd si l'écran est assez grand. Renvoie true si
// la police a changé.
func BiggerFont(fd int) bool {
	var ws winsize
	if ioctl(fd, syscall.TIOCGWINSZ, unsafe.Pointer(&ws)) != nil {
		return false
	}
	if int(ws.Cols)/2 < minColsBigger || int(ws.Rows)/2 < minRowsBigger {
		return false
	}

	// police actuelle (au plus 512 caractères de 32×32)
	src := make([]byte, 512*fontVPitch*4)
	op := consoleFontOp{Op: kdFontOpGet, Width: 32, Height: 32, Charcount: 512, Data: uintptr(unsafe.Pointer(&src[0]))}
	if ioctl(fd, kdFontOp, unsafe.Pointer(&op)) != nil {
		return false
	}
	w, h, n := int(op.Width), int(op.Height), int(op.Charcount)
	if w == 0 || h == 0 || n == 0 || w*2 > 32 || h*2 > 32 {
		return false
	}

	dst := doubleFont(src, w, h, n)
	set := consoleFontOp{Op: kdFontOpSet, Width: uint32(w * 2), Height: uint32(h * 2), Charcount: uint32(n), Data: uintptr(unsafe.Pointer(&dst[0]))}
	return ioctl(fd, kdFontOp, unsafe.Pointer(&set)) == nil
}

// doubleFont agrandit chaque pixel en 2×2. Format du noyau : chaque caractère occupe 32
// lignes de ceil(largeur/8) octets, bit de poids fort à gauche.
func doubleFont(src []byte, w, h, n int) []byte {
	sp, dp := (w+7)/8, (2*w+7)/8
	dst := make([]byte, n*fontVPitch*dp)
	for c := 0; c < n; c++ {
		for y := 0; y < h; y++ {
			row := src[(c*fontVPitch+y)*sp:]
			for x := 0; x < w; x++ {
				if row[x/8]&(0x80>>(x%8)) == 0 {
					continue
				}
				for dy := 0; dy < 2; dy++ {
					out := dst[(c*fontVPitch+2*y+dy)*dp:]
					for dx := 0; dx < 2; dx++ {
						X := 2*x + dx
						out[X/8] |= 0x80 >> (X % 8)
					}
				}
			}
		}
	}
	return dst
}
