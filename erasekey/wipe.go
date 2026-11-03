package main

import (
	"bytes"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// Les méthodes proposées. `Work` : combien de fois le disque est parcouru en tout
// (écritures + relecture), pour estimer l'avancement.
type Method struct {
	Title  string
	Detail string
	Args   []string
	Work   float64
}

var methods = []Method{
	{"Conseillée", "données aléatoires, remise à zéro, puis relecture", []string{"--method=prng", "--verify=last"}, 3},
	{"Rapide", "une passe de zéros, puis relecture", []string{"--method=zero", "--verify=last", "--noblank"}, 2},
	{"Renforcée", "trois passes (norme DoD), remise à zéro, relecture", []string{"--method=dodshort", "--verify=last"}, 5},
}

// Un effacement en cours : nwipe tourne en mode automatique, sans son interface.
type Wipe struct {
	Disks   []Disk
	Method  Method
	Started time.Time
	start   map[string]int64
	cmd     *exec.Cmd
	out     bytes.Buffer
	done    chan error
	Err     error
	Ended   time.Time
	Results map[string]string // disque → « réussi », « échoué »…
}

func StartWipe(disks []Disk, m Method, logfile string) (*Wipe, error) {
	w := &Wipe{Disks: disks, Method: m, Started: time.Now(), start: map[string]int64{}, done: make(chan error, 1), Results: map[string]string{}}
	for _, d := range disks {
		w.start[d.Name] = IOBytes(d.Name)
	}
	if demo {
		demoStart = time.Now()
		go func() { time.Sleep(demoLength); w.done <- nil }()
		return w, nil
	}
	args := []string{"--autonuke", "--nogui", "--nowait", "--nousb"}
	if logfile != "" {
		args = append(args, "--logfile="+logfile)
	}
	args = append(args, m.Args...)
	for _, d := range disks {
		args = append(args, d.Dev())
	}
	w.cmd = exec.Command("/usr/bin/nwipe", args...)
	w.cmd.Stdout = &w.out
	w.cmd.Stderr = &w.out
	w.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := w.cmd.Start(); err != nil {
		return nil, err
	}
	go func() { w.done <- w.cmd.Wait() }()
	return w, nil
}

// Avancement d'un disque (0…1), d'après ce qui a été lu et écrit dessus.
func (w *Wipe) Progress(d Disk) float64 {
	total := float64(d.Size) * w.Method.Work
	if total <= 0 {
		return 0
	}
	p := float64(IOBytes(d.Name)-w.start[d.Name]) / total
	if p > 0.995 {
		p = 0.995 // la fin, c'est nwipe qui la dit
	}
	if p < 0 {
		p = 0
	}
	return p
}

func (w *Wipe) Overall() float64 {
	var done, total float64
	for _, d := range w.Disks {
		done += w.Progress(d) * float64(d.Size)
		total += float64(d.Size)
	}
	if total == 0 {
		return 0
	}
	return done / total
}

// Débit actuel (octets par seconde) depuis le début.
func (w *Wipe) Speed() float64 {
	el := time.Since(w.Started).Seconds()
	if el < 1 {
		return 0
	}
	var b int64
	for _, d := range w.Disks {
		b += IOBytes(d.Name) - w.start[d.Name]
	}
	return float64(b) / el
}

func (w *Wipe) Remaining() time.Duration {
	p := w.Overall()
	el := time.Since(w.Started)
	if p < 0.01 || el < 5*time.Second {
		return 0
	}
	return time.Duration(float64(el) * (1 - p) / p)
}

// Arrêt demandé : nwipe s'arrête proprement sur Ctrl+C (SIGINT).
func (w *Wipe) Cancel() {
	if w.cmd != nil && w.cmd.Process != nil {
		_ = syscall.Kill(-w.cmd.Process.Pid, syscall.SIGINT)
	}
}

// Résultat de chaque disque, lu dans le journal de nwipe (son tableau final).
func (w *Wipe) Finish(err error, logfile string) {
	w.Err = err
	w.Ended = time.Now()
	text := w.out.String()
	if logfile != "" {
		if b, e := os.ReadFile(logfile); e == nil {
			text += "\n" + string(b)
		}
	}
	for _, d := range w.Disks {
		w.Results[d.Name] = verdict(text, d.Name, err)
	}
}

var failWords = regexp.MustCompile(`(?i)(fail|error|abort|not erased|unsuccessful)`)

func verdict(log, name string, err error) string {
	if demo {
		return "réussi"
	}
	var lines []string
	for _, l := range strings.Split(log, "\n") {
		if strings.Contains(l, "/dev/"+name) || strings.Contains(l, " "+name+" ") {
			lines = append(lines, l)
		}
	}
	for _, l := range lines {
		if strings.Contains(strings.ToLower(l), "erased") && !failWords.MatchString(l) {
			return "réussi"
		}
	}
	for _, l := range lines {
		if failWords.MatchString(l) {
			return "échoué"
		}
	}
	if err == nil {
		return "réussi"
	}
	return "échoué"
}

// Les journaux et rapports PDF partent sur la clé (outil de ShredOS), puis on éteint.
func SaveReports() {
	if demo {
		return
	}
	_ = exec.Command("/usr/bin/archive_log.sh", "-w").Run()
}

func PowerOff(reboot bool) {
	if demo {
		os.Exit(0)
	}
	SaveReports()
	if reboot {
		_ = exec.Command("/sbin/reboot").Run()
	} else {
		_ = exec.Command("/sbin/poweroff").Run()
	}
}
