// EraseKEY : l'interface d'effacement d'OsaBoot, dans le style de la suite Osa.
//
// Elle remplace l'écran de nwipe sur la clé ShredOS : on choisit le disque, la méthode, on
// confirme en tapant EFFACER, puis nwipe efface en mode automatique pendant qu'on suit
// l'avancement. La clé elle-même n'est jamais proposée.
//
// Lancée par le lanceur de ShredOS (nwipe_launcher, retouché par OsaBoot) avec ses options :
//   osa-erase --logfile=nwipe_log_….txt --exclude=/dev/sdb
package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

var version = "dev"

type screen int

const (
	scrDisks screen = iota
	scrMethod
	scrConfirm
	scrWiping
	scrDone
)

type model struct {
	scr      screen
	disks    []Disk
	cursor   int
	picked   map[string]bool
	method   int
	input    textinput.Model
	wipe     *Wipe
	frame    int
	w, h     int
	logfile  string
	exclude  map[string]bool
	asking   bool // « Arrêter l'effacement ? »
	mistyped bool
}

type tick struct{}
type wipeDone struct{ err error }

func every() tea.Cmd { return tea.Tick(350*time.Millisecond, func(time.Time) tea.Msg { return tick{} }) }

func newModel(logfile string, exclude map[string]bool) model {
	ti := textinput.New()
	ti.Placeholder = "EFFACER"
	ti.CharLimit = 12
	ti.Width = 14
	ti.Prompt = "► "
	m := model{picked: map[string]bool{}, input: ti, logfile: logfile, exclude: exclude, w: 100, h: 34}
	m.disks = ScanDisks(exclude)
	return m
}

func (m model) Init() tea.Cmd { return every() }

func (m model) selectable() []Disk {
	var out []Disk
	for _, d := range m.disks {
		if !d.Protected {
			out = append(out, d)
		}
	}
	return out
}

// Les disques à effacer : ceux cochés, sinon celui sous le curseur.
func (m model) chosen() []Disk {
	var out []Disk
	for _, d := range m.selectable() {
		if m.picked[d.Name] {
			out = append(out, d)
		}
	}
	if len(out) == 0 {
		if s := m.selectable(); m.cursor < len(s) {
			out = append(out, s[m.cursor])
		}
	}
	return out
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		return m, nil
	case tick:
		m.frame++
		return m, every()
	case wipeDone:
		m.wipe.Finish(msg.err, m.logfile)
		m.scr = scrDone
		m.asking = false
		SaveReports()
		return m, nil
	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

func (m model) key(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	s := k.String()
	switch m.scr {
	case scrDisks:
		sel := m.selectable()
		switch s {
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < len(sel)-1 {
				m.cursor++
			}
		case " ":
			if m.cursor < len(sel) {
				n := sel[m.cursor].Name
				m.picked[n] = !m.picked[n]
			}
		case "r", "R":
			m.disks = ScanDisks(m.exclude)
			m.picked = map[string]bool{}
			m.cursor = 0
		case "enter":
			if len(m.chosen()) > 0 {
				m.scr = scrMethod
			}
		case "f10", "ctrl+e":
			PowerOff(false)
		}
	case scrMethod:
		switch s {
		case "up", "k":
			if m.method > 0 {
				m.method--
			}
		case "down", "j":
			if m.method < len(methods)-1 {
				m.method++
			}
		case "esc", "backspace", "left":
			m.scr = scrDisks
		case "enter":
			m.scr = scrConfirm
			m.input.SetValue("")
			m.mistyped = false
			m.input.Focus()
			return m, textinput.Blink
		}
	case scrConfirm:
		switch s {
		case "esc":
			m.scr = scrMethod
			m.input.Blur()
			return m, nil
		case "enter":
			if strings.EqualFold(strings.TrimSpace(m.input.Value()), "EFFACER") {
				w, err := StartWipe(m.chosen(), methods[m.method], m.logfile)
				if err != nil {
					m.mistyped = false
					m.input.SetValue("")
					m.wipe = &Wipe{Disks: m.chosen(), Results: map[string]string{}, Err: err, Ended: time.Now(), Started: time.Now()}
					m.scr = scrDone
					return m, nil
				}
				m.wipe = w
				m.scr = scrWiping
				return m, func() tea.Msg { return wipeDone{<-w.done} }
			}
			m.mistyped = true
			return m, nil
		}
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(k)
		m.mistyped = false
		return m, cmd
	case scrWiping:
		if m.asking {
			switch s {
			case "o", "O", "y", "Y":
				m.wipe.Cancel()
				m.asking = false
			default:
				m.asking = false
			}
			return m, nil
		}
		if s == "ctrl+c" || s == "a" || s == "A" {
			m.asking = true
		}
	case scrDone:
		switch s {
		case "enter":
			return m, tea.Quit // le lanceur de ShredOS range les rapports et nous relance
		case "e", "E":
			PowerOff(false)
		case "r", "R":
			PowerOff(true)
		}
	}
	return m, nil
}

// MARK: dessin

var (
	white  = lipgloss.Color("15")
	grey   = lipgloss.Color("7")
	dim    = lipgloss.Color("8")
	green  = lipgloss.Color("10")
	red    = lipgloss.Color("9")
	tW     = lipgloss.NewStyle().Foreground(white).Bold(true)
	tG     = lipgloss.NewStyle().Foreground(grey)
	tD     = lipgloss.NewStyle().Foreground(dim)
	tOk    = lipgloss.NewStyle().Foreground(green).Bold(true)
	tBad   = lipgloss.NewStyle().Foreground(red).Bold(true)
	bubble = lipgloss.NewStyle().Border(lipgloss.NormalBorder()).BorderForeground(grey).Padding(0, 2).Foreground(white)
	panel  = lipgloss.NewStyle().Border(lipgloss.NormalBorder()).BorderForeground(dim).Padding(1, 2)
)

func (m model) View() string {
	width := min(m.w-4, 92)
	head := lipgloss.JoinHorizontal(lipgloss.Top,
		tW.Render("▀▄ EraseKEY"), tD.Render("  par OsaBoot · OsaLabs"))
	head = lipgloss.PlaceHorizontal(width, lipgloss.Left, head)

	mood, say := m.mascotState()
	talk := lipgloss.JoinHorizontal(lipgloss.Center,
		lipgloss.NewStyle().Foreground(white).Render(Mascot(mood, m.frame)), "  ",
		bubble.Width(min(width-22, 60)).Render(say))

	var body, keys string
	switch m.scr {
	case scrDisks:
		body, keys = m.viewDisks(width), "↑↓ choisir · Espace cocher plusieurs · Entrée continuer · R relire · F10 éteindre"
	case scrMethod:
		body, keys = m.viewMethod(width), "↑↓ choisir · Entrée continuer · Échap revenir"
	case scrConfirm:
		body, keys = m.viewConfirm(width), "tape EFFACER puis Entrée · Échap revenir"
	case scrWiping:
		body, keys = m.viewWiping(width), "A arrêter"
		if m.asking {
			keys = tBad.Render("Arrêter l'effacement ? Le disque sera à moitié effacé. O = oui, autre touche = non")
		}
	case scrDone:
		body, keys = m.viewDone(width), "Entrée effacer un autre disque · E éteindre le PC · R redémarrer"
	}
	page := lipgloss.JoinVertical(lipgloss.Left, head, "", talk, "", body, "", tD.Render(keys))
	return lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center, page)
}

func (m model) mascotState() (Mood, string) {
	switch m.scr {
	case scrDisks:
		if len(m.selectable()) == 0 {
			return Worried, "Je ne trouve aucun disque à effacer sur ce PC. Vérifie qu'il est bien branché, puis appuie sur R."
		}
		return Calm, "Salut ! Quel disque veux-tu effacer complètement ? Ta clé EraseKEY est protégée, je n'y toucherai pas."
	case scrMethod:
		return Calm, "Comment l'effacer ? La méthode conseillée suffit pour un disque qu'on donne ou qu'on vend."
	case scrConfirm:
		return Worried, "Dernière vérification : tout ce qu'il y a dessus va disparaître pour toujours. Rien ne pourra être récupéré."
	case scrWiping:
		return Busy, "J'efface... Laisse le PC allumé et la clé branchée. Tu peux aller boire un café."
	case scrDone:
		if m.allOK() {
			return Happy, "C'est fait ! Le disque est vide et vérifié. Le rapport est enregistré sur la clé."
		}
		return Worried, "Ça ne s'est pas bien passé. Le détail est dans le journal enregistré sur la clé."
	}
	return Calm, ""
}

func (m model) allOK() bool {
	if m.wipe == nil || (m.wipe.Err != nil && len(m.wipe.Results) == 0) {
		return false
	}
	for _, d := range m.wipe.Disks {
		if m.wipe.Results[d.Name] != "réussi" {
			return false
		}
	}
	return true
}

func diskLine(d Disk) string {
	extra := d.Kind
	if d.Serial != "" {
		extra += " · n° " + d.Serial
	}
	return fmt.Sprintf("%-34s %9s   %s", trunc(d.Model, 34), human(d.Size), extra)
}

func trunc(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-3]) + "..."
}

func (m model) viewDisks(width int) string {
	var rows []string
	sel := m.selectable()
	for i, d := range sel {
		box := "[ ]"
		if m.picked[d.Name] {
			box = "[■]"
		}
		line := box + "  " + diskLine(d)
		if i == m.cursor {
			rows = append(rows, tW.Render("► "+line))
		} else {
			rows = append(rows, tG.Render("  "+line))
		}
	}
	for _, d := range m.disks {
		if d.Protected {
			rows = append(rows, tD.Render("       "+fmt.Sprintf("%-34s %9s   protégé : %s", trunc(d.Model, 34), human(d.Size), d.Reason)))
		}
	}
	if len(rows) == 0 {
		rows = append(rows, tD.Render("aucun disque"))
	}
	return panel.Width(width).Render(tW.Render("Les disques de ce PC") + "\n\n" + strings.Join(rows, "\n"))
}

func (m model) viewMethod(width int) string {
	var rows []string
	for i, x := range methods {
		mark, st := "  ", tG
		if i == m.method {
			mark, st = "► ", tW
		}
		rows = append(rows, st.Render(fmt.Sprintf("%s%-12s", mark, x.Title))+tD.Render(x.Detail))
	}
	what := []string{}
	for _, d := range m.chosen() {
		what = append(what, d.Model+" ("+human(d.Size)+")")
	}
	return panel.Width(width).Render(tW.Render("Méthode") + tD.Render("  pour "+strings.Join(what, ", ")) + "\n\n" + strings.Join(rows, "\n\n"))
}

func (m model) viewConfirm(width int) string {
	var rows []string
	for _, d := range m.chosen() {
		rows = append(rows, tW.Render("■ "+d.Model)+tG.Render("   "+human(d.Size)+" · "+d.Kind+" · "+d.Dev()))
		if d.Serial != "" {
			rows = append(rows, tD.Render("  numéro de série "+d.Serial))
		}
		if d.Parts > 0 {
			rows = append(rows, tD.Render(fmt.Sprintf("  %d partition(s) : elles disparaîtront toutes", d.Parts)))
		}
	}
	hint := tD.Render("Méthode : " + methods[m.method].Title + ", " + methods[m.method].Detail)
	field := m.input.View()
	if m.mistyped {
		field += tBad.Render("   Ce n'est pas EFFACER.")
	}
	return panel.BorderForeground(red).Width(width).Render(
		tBad.Render("Tout va être effacé, sans retour possible") + "\n\n" + strings.Join(rows, "\n") + "\n\n" + hint +
			"\n\n" + tW.Render("Pour confirmer, tape EFFACER :") + "\n" + field)
}

func bar(p float64, w int) string {
	n := int(p * float64(w))
	if n > w {
		n = w
	}
	return tW.Render(strings.Repeat("█", n)) + tD.Render(strings.Repeat("░", w-n))
}

func dur(d time.Duration) string {
	d = d.Round(time.Minute)
	if d < time.Minute {
		return "moins d'une minute"
	}
	h, mn := int(d.Hours()), int(d.Minutes())%60
	if h == 0 {
		return fmt.Sprintf("%d min", mn)
	}
	return fmt.Sprintf("%d h %02d", h, mn)
}

func (m model) viewWiping(width int) string {
	w := m.wipe
	bw := width - 16
	var rows []string
	for _, d := range w.Disks {
		p := w.Progress(d)
		rows = append(rows, tW.Render(trunc(d.Model, 40))+tD.Render("  "+human(d.Size)))
		rows = append(rows, bar(p, bw)+tW.Render(fmt.Sprintf("  %3d %%", int(p*100))))
	}
	dots := strings.Repeat("·", m.frame%4)
	info := fmt.Sprintf("Méthode %s · depuis %s", strings.ToLower(w.Method.Title), dur(time.Since(w.Started)))
	if s := w.Speed(); s > 0 {
		info += " · " + human(int64(s)) + "/s"
	}
	if r := w.Remaining(); r >= time.Minute {
		info += " · encore environ " + dur(r)
	}
	return panel.Width(width).Render(tW.Render("Effacement en cours"+dots) + "\n\n" + strings.Join(rows, "\n") + "\n\n" + tD.Render(info))
}

func (m model) viewDone(width int) string {
	w := m.wipe
	var rows []string
	for _, d := range w.Disks {
		r := w.Results[d.Name]
		mark := tOk.Render("√ réussi")
		if r != "réussi" {
			mark = tBad.Render("× " + map[bool]string{true: r, false: "échoué"}[r != ""])
		}
		rows = append(rows, fmt.Sprintf("%s  %s", mark, tW.Render(d.Model)+tD.Render("  "+human(d.Size))))
	}
	if w.Err != nil && len(w.Results) == 0 {
		rows = append(rows, tBad.Render("nwipe n'a pas pu démarrer : "+w.Err.Error()))
	}
	info := fmt.Sprintf("Durée : %s · méthode %s", dur(w.Ended.Sub(w.Started)), strings.ToLower(w.Method.Title))
	return panel.Width(width).Render(tW.Render("Terminé") + "\n\n" + strings.Join(rows, "\n") + "\n\n" + tD.Render(info) +
		"\n" + tD.Render("Journal et rapport PDF : sur la clé, à côté du LISEZMOI."))
}

func main() {
	logfile := ""
	exclude := map[string]bool{}
	render := ""
	for _, a := range os.Args[1:] {
		switch {
		case strings.HasPrefix(a, "--logfile="):
			logfile = strings.TrimPrefix(a, "--logfile=")
		case strings.HasPrefix(a, "--exclude="):
			exclude[strings.TrimPrefix(a, "--exclude=")] = true
		case strings.HasPrefix(a, "--render="):
			render = strings.TrimPrefix(a, "--render=")
		case a == "--version":
			fmt.Println("osa-erase", version)
			return
		}
	}
	// deuxième sécurité : la clé repérée par ShredOS au démarrage
	if b, err := os.ReadFile("/boot_device.txt"); err == nil {
		if dev := strings.TrimSpace(string(b)); dev != "" {
			exclude[dev] = true
		}
	}
	demo = os.Getenv("OSA_DEMO") != "" || render != ""

	if render != "" {
		lipgloss.SetColorProfile(termenv.Ascii)
		fmt.Println(preview(render, logfile, exclude))
		return
	}
	// texte plus gros sur les écrans haute définition (console Linux seulement)
	if !demo {
		BiggerFont(int(os.Stdin.Fd()))
	}
	p := tea.NewProgram(newModel(logfile, exclude), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Println("erreur :", err)
		time.Sleep(5 * time.Second)
		os.Exit(1)
	}
}

// Aperçu texte d'un écran (pour vérifier la mise en page sans PC à effacer).
func preview(which, logfile string, exclude map[string]bool) string {
	m := newModel(logfile, exclude)
	m.w, m.h = 100, 34
	m.frame = 1
	switch which {
	case "methode":
		m.scr = scrMethod
	case "confirmation":
		m.scr = scrConfirm
		m.input.Focus()
		m.input.SetValue("EFF")
	case "effacement":
		m.wipe, _ = StartWipe(m.chosen(), methods[0], "")
		demoStart = time.Now().Add(-14 * time.Second)
		m.wipe.Started = demoStart
		m.scr = scrWiping
	case "fin":
		m.wipe, _ = StartWipe(m.chosen(), methods[0], "")
		m.wipe.Finish(nil, "")
		m.wipe.Ended = m.wipe.Started.Add(83 * time.Minute)
		m.scr = scrDone
	}
	return m.View()
}
