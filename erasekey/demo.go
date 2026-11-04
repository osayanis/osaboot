package main

import "time"

// Mode démo (OSA_DEMO=1) : de faux disques et un faux effacement, pour voir l'interface
// sans rien toucher.

var (
	demo       = false
	demoStart  time.Time
	demoLength = 40 * time.Second
	demoSpeed  = 412e6 // débit affiché en démo, vraisemblable pour un SSD (octets/s)
)

func demoDisks() []Disk {
	return []Disk{
		{Name: "nvme0n1", Model: "Samsung SSD 980 PRO 1TB", Serial: "S5GXNF0R123456", Size: 1_000_204_886_016, Kind: "NVMe", Parts: 4},
		{Name: "sda", Model: "ATA ST2000DM008-2FR102", Serial: "ZFL1ABCD", Size: 2_000_398_934_016, Kind: "Disque dur", Parts: 1},
		{Name: "sdb", Model: "SanDisk Ultra", Size: 32_010_928_128, Kind: "USB", Parts: 1, Protected: true, Reason: "ta clé EraseKEY"},
	}
}

func demoIO(name string) int64 {
	if demoStart.IsZero() {
		return 0
	}
	p := float64(time.Since(demoStart)) / float64(demoLength)
	if p > 1 {
		p = 1
	}
	for _, d := range demoDisks() {
		if d.Name == name {
			return int64(p * float64(d.Size) * 3)
		}
	}
	return 0
}
