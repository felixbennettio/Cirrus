package app

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"cirrus/server/internal/config"
)

// Installers can be served by the site itself: files in DATA_DIR/downloads
// are served at /downloads/<file>, and DATA_DIR/downloads/manifest.json
// (written by scripts/publish_download.sh) says which file belongs to which
// platform:
//
//	{"version": "1.2.0",
//	 "files": {"macos": {"file": "Cirrus-1.2.0-macos-universal.dmg", "sha256": "…"},
//	           "linux": [{"file": "Cirrus-1.2.0-linux-x86_64.AppImage", "sha256": "…", "version": "1.2.0"}, …]}}
//
// A platform listed in the manifest (with at least one file present) takes
// precedence over its DOWNLOAD_URL_<PLATFORM> setting, which remains the way
// to link to files hosted elsewhere.

const manifestName = "manifest.json"

// downloadName is what may be served from the downloads directory: plain
// file names, no directories, no dotfiles (uploads in progress use those).
var downloadName = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]*$`)

// dlFile is one file of a platform's download.
type dlFile struct {
	Name   string // file name, shown when a platform has several files
	URL    string // site-relative (/downloads/…) or absolute
	SHA256 string
	Size   int64 // bytes; 0 when unknown (externally hosted)
}

// dlPlatform is what the downloads page shows for a platform.
type dlPlatform struct {
	Platform string
	Version  string
	Files    []dlFile
}

type manifestEntry struct {
	File    string `json:"file"`
	SHA256  string `json:"sha256"`
	Version string `json:"version"`
}

type manifest struct {
	Version string                     `json:"version"`
	Files   map[string]json.RawMessage `json:"files"`
}

// manifestCache re-reads manifest.json when its modification time or size
// changes.
type manifestCache struct {
	mu      sync.Mutex
	modTime time.Time
	size    int64
	m       *manifest
}

func (a *App) downloadsDir() string { return filepath.Join(a.cfg.DataDir, "downloads") }

func (a *App) manifest() *manifest {
	path := filepath.Join(a.downloadsDir(), manifestName)
	st, err := os.Stat(path)
	c := &a.manifestCache
	c.mu.Lock()
	defer c.mu.Unlock()
	if err != nil || !st.Mode().IsRegular() {
		c.m, c.modTime, c.size = nil, time.Time{}, 0
		return nil
	}
	if c.m != nil && st.ModTime().Equal(c.modTime) && st.Size() == c.size {
		return c.m
	}
	c.modTime, c.size, c.m = st.ModTime(), st.Size(), &manifest{}
	f, err := os.Open(path)
	if err == nil {
		defer f.Close()
		err = json.NewDecoder(io.LimitReader(f, 1<<20)).Decode(c.m)
	}
	if err != nil {
		a.log.Error("downloads manifest unreadable; ignoring it", "path", path, "err", err)
		c.m = &manifest{}
	}
	return c.m
}

// manifestFiles returns the files the manifest lists for a platform that are
// present in the downloads directory.
func (a *App) manifestFiles(m *manifest, platform string) (files []dlFile, version string) {
	raw, ok := m.Files[platform]
	if !ok {
		return nil, ""
	}
	var entries []manifestEntry
	if err := json.Unmarshal(raw, &entries); err != nil {
		var one manifestEntry
		if json.Unmarshal(raw, &one) != nil {
			return nil, ""
		}
		entries = []manifestEntry{one}
	}
	for _, e := range entries {
		if !downloadName.MatchString(e.File) || e.File == manifestName {
			continue
		}
		st, err := os.Lstat(filepath.Join(a.downloadsDir(), e.File))
		if err != nil || !st.Mode().IsRegular() {
			continue
		}
		sum := strings.ToLower(strings.TrimSpace(e.SHA256))
		if !validSHA256(sum) {
			sum = ""
		}
		if version == "" {
			version = strings.TrimSpace(e.Version)
		}
		files = append(files, dlFile{Name: e.File, URL: "/downloads/" + url.PathEscape(e.File), SHA256: sum, Size: st.Size()})
	}
	if version == "" && len(files) > 0 {
		version = strings.TrimSpace(m.Version)
	}
	if len(version) > 40 {
		version = version[:40]
	}
	return files, version
}

func validSHA256(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, r := range s {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}

// downloads lists the available download of each platform, in display
// order: files from the manifest, else the DOWNLOAD_URL_<PLATFORM> link.
func (a *App) downloads() []dlPlatform {
	m := a.manifest()
	var out []dlPlatform
	for _, p := range config.Platforms() {
		if m != nil {
			if files, version := a.manifestFiles(m, p); len(files) > 0 {
				out = append(out, dlPlatform{Platform: p, Version: version, Files: files})
				continue
			}
		}
		if d, ok := a.cfg.Download(p); ok {
			name := d.URL
			if u, err := url.Parse(d.URL); err == nil && u.Path != "" {
				name = filepath.Base(u.Path)
			}
			out = append(out, dlPlatform{Platform: p, Version: d.Version, Files: []dlFile{{Name: name, URL: d.URL, SHA256: d.SHA256}}})
		}
	}
	return out
}

// downloadLink is the link for a platform in the licence email: the file
// itself when there is one, the downloads page when there are several, the
// general DOWNLOAD_URL when the platform has none, else "".
func (a *App) downloadLink(platform string) string {
	for _, d := range a.downloads() {
		if d.Platform != platform {
			continue
		}
		if len(d.Files) == 1 {
			return a.absURL(d.Files[0].URL)
		}
		return a.cfg.PublicURL + "/download#" + platform
	}
	return a.cfg.DownloadURL
}

func (a *App) absURL(u string) string {
	if strings.HasPrefix(u, "/") {
		return a.cfg.PublicURL + u
	}
	return u
}

var downloadTypes = []struct{ suffix, ctype string }{
	{".tar.gz", "application/gzip"},
	{".tgz", "application/gzip"},
	{".dmg", "application/x-apple-diskimage"},
	{".pkg", "application/octet-stream"},
	{".exe", "application/vnd.microsoft.portable-executable"},
	{".msi", "application/x-msi"},
	{".msix", "application/msix"},
	{".zip", "application/zip"},
	{".apk", "application/vnd.android.package-archive"},
	{".aab", "application/octet-stream"}, // Android App Bundle: no registered type
	{".appimage", "application/vnd.appimage"},
	{".deb", "application/vnd.debian.binary-package"},
	{".rpm", "application/x-rpm"},
	{".ipa", "application/octet-stream"},
	{".gz", "application/gzip"},
	{".xz", "application/x-xz"},
	{".txt", "text/plain; charset=utf-8"},
	{".asc", "text/plain; charset=utf-8"},
	{".sig", "application/pgp-signature"},
}

func downloadType(name string) string {
	lower := strings.ToLower(name)
	for _, t := range downloadTypes {
		if strings.HasSuffix(lower, t.suffix) {
			return t.ctype
		}
	}
	return "application/octet-stream"
}

// serveDownload serves a file from DATA_DIR/downloads. File names carry the
// version, so responses are cacheable for good (also by the CDN).
func (a *App) serveDownload(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("file")
	if !downloadName.MatchString(name) || name == manifestName {
		a.notFound(w, r)
		return
	}
	path := filepath.Join(a.downloadsDir(), name)
	// Lstat: a symbolic link is not followed out of the directory.
	if st, err := os.Lstat(path); err != nil || !st.Mode().IsRegular() {
		a.notFound(w, r)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		a.notFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		a.notFound(w, r)
		return
	}
	// Installers are large; allow far more than the server's WriteTimeout.
	http.NewResponseController(w).SetWriteDeadline(time.Now().Add(2 * time.Hour))
	h := w.Header()
	h.Set("Content-Type", downloadType(name))
	h.Set("Content-Disposition", `attachment; filename="`+name+`"`)
	h.Set("Cache-Control", "public, max-age=31536000, immutable")
	http.ServeContent(w, r, name, st.ModTime(), f)
}
