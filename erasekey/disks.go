package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Un disque du PC, lu dans /sys/block.
type Disk struct {
	Name      string // sda, nvme0n1…
	Model     string
	Serial    string
	Size      int64
	Kind      string // SSD, Disque dur, NVMe, USB, Carte SD
	Parts     int
	Protected bool   // la clé EraseKEY elle-même : jamais effaçable
	Reason    string // pourquoi il est protégé
}

func (d Disk) Dev() string { return "/dev/" + d.Name }

func read(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// Disques du PC. `exclude` : chemins /dev/… à protéger (la clé de démarrage).
func ScanDisks(exclude map[string]bool) []Disk {
	if demo {
		return demoDisks()
	}
	entries, _ := os.ReadDir("/sys/block")
	var out []Disk
	for _, e := range entries {
		n := e.Name()
		if skipName(n) {
			continue
		}
		base := "/sys/block/" + n
		size, _ := strconv.ParseInt(read(base+"/size"), 10, 64)
		if size == 0 {
			continue
		}
		d := Disk{Name: n, Size: size * 512}
		d.Model = strings.Join(strings.Fields(read(base+"/device/vendor")+" "+read(base+"/device/model")), " ")
		if d.Model == "" {
			d.Model = "Disque sans nom"
		}
		d.Serial = read(base + "/device/serial")
		real, _ := filepath.EvalSymlinks(base)
		switch {
		case strings.HasPrefix(n, "nvme"):
			d.Kind = "NVMe"
		case strings.HasPrefix(n, "mmcblk"):
			d.Kind = "Carte SD"
		case strings.Contains(real, "/usb"):
			d.Kind = "USB"
		case read(base+"/queue/rotational") == "1":
			d.Kind = "Disque dur"
		default:
			d.Kind = "SSD"
		}
		parts, _ := filepath.Glob(base + "/" + n + "*")
		d.Parts = len(parts)
		if exclude[d.Dev()] {
			d.Protected, d.Reason = true, "ta clé EraseKEY"
		} else if hasMounted(n) {
			d.Protected, d.Reason = true, "utilisé par le système"
		}
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Protected != out[j].Protected {
			return !out[i].Protected
		}
		return out[i].Name < out[j].Name
	})
	return out
}

func skipName(n string) bool {
	for _, p := range []string{"loop", "ram", "zram", "sr", "fd", "dm-", "md", "nbd"} {
		if strings.HasPrefix(n, p) {
			return true
		}
	}
	return strings.Contains(n, "boot") || strings.Contains(n, "rpmb")
}

// Une partition du disque est montée (la clé, par exemple) : on n'y touche pas.
func hasMounted(name string) bool {
	f, err := os.Open("/proc/mounts")
	if err != nil {
		return false
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		dev := strings.Fields(s.Text())
		if len(dev) > 0 && strings.HasPrefix(dev[0], "/dev/"+name) {
			return true
		}
	}
	return false
}

// Octets lus + écrits sur le disque depuis le démarrage (/proc/diskstats, secteurs de 512).
func IOBytes(name string) int64 {
	if demo {
		return demoIO(name)
	}
	f, err := os.Open("/proc/diskstats")
	if err != nil {
		return 0
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		x := strings.Fields(s.Text())
		if len(x) > 9 && x[2] == name {
			r, _ := strconv.ParseInt(x[5], 10, 64)
			w, _ := strconv.ParseInt(x[9], 10, 64)
			return (r + w) * 512
		}
	}
	return 0
}

func human(b int64) string {
	units := []string{"o", "Ko", "Mo", "Go", "To"}
	v := float64(b)
	i := 0
	for v >= 1000 && i < len(units)-1 {
		v /= 1000
		i++
	}
	if v >= 100 || i == 0 {
		return fmt.Sprintf("%.0f %s", v, units[i])
	}
	return strings.Replace(fmt.Sprintf("%.1f %s", v, units[i]), ".", ",", 1)
}
