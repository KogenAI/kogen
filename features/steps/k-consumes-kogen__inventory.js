'use strict';
// The Go source of the inventory helper that k-consumes-kogen__suites.js builds outside the checkout and
// runs on a module directory. For that module it reports which objects of each dependency module the
// module's non-test packages use, and what each consumes/<dependency>/ suite references, imports and
// documents, as one JSON object. It is kept here so that every new step-folder file is JavaScript.
module.exports = {
  source: String.raw`// Command k-consumes-kogen__inventory reports, for the Go module in the directory it is given,
// which objects of each dependency module the module's non-test packages use, and what each
// consumes/<dependency>/ suite references, imports and documents. It prints one JSON object.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type listed struct {
	ImportPath     string
	Dir            string
	Export         string
	Standard       bool
	GoFiles        []string
	TestGoFiles    []string
	XTestGoFiles   []string
	IgnoredGoFiles []string
	Module         *struct{ Path string }
}

type suite struct {
	Files            int      ${'`'}json:"files"${'`'}
	Tests            int      ${'`'}json:"tests"${'`'}
	Referenced       []string ${'`'}json:"referenced"${'`'}
	Missing          []string ${'`'}json:"missing"${'`'}
	Extra            []string ${'`'}json:"extra"${'`'}
	Imports          []string ${'`'}json:"imports"${'`'}
	ForbiddenImports []string ${'`'}json:"forbidden_imports"${'`'}
	Skips            []string ${'`'}json:"skips"${'`'}
	Constraints      []string ${'`'}json:"constraints"${'`'}
	HostPaths        []string ${'`'}json:"host_paths"${'`'}
	Readme           bool     ${'`'}json:"readme"${'`'}
	ReadmeMissing    []string ${'`'}json:"readme_missing"${'`'}
}

type report struct {
	Module string              ${'`'}json:"module"${'`'}
	Used   map[string][]string ${'`'}json:"used"${'`'}
	Suites map[string]*suite   ${'`'}json:"suites"${'`'}
	Errors []string            ${'`'}json:"errors"${'`'}
}

var hostPath = regexp.MustCompile(${'`'}/Users/[^/<]+/|/home/[^/<]+/|/var/folders/${'`'})

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: inventory <module-dir>")
		os.Exit(2)
	}
	r, err := inventory(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(r); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func goList(dir string, args ...string) ([]listed, error) {
	cmd := exec.Command("go", append([]string{"list", "-e", "-json"}, args...)...)
	cmd.Dir = dir
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("go list %s: %v\n%s", strings.Join(args, " "), err, stderr.String())
	}
	var pkgs []listed
	dec := json.NewDecoder(bytes.NewReader(out))
	for {
		var p listed
		if err := dec.Decode(&p); err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		}
		pkgs = append(pkgs, p)
	}
	return pkgs, nil
}

func inventory(dir string) (*report, error) {
	modOut, err := exec.Command("go", "-C", dir, "list", "-m").Output()
	if err != nil {
		return nil, fmt.Errorf("go list -m: %v", err)
	}
	mainMod := strings.TrimSpace(string(modOut))
	r := &report{Module: mainMod, Used: map[string][]string{}, Suites: map[string]*suite{}, Errors: []string{}}

	own, err := goList(dir, "./...")
	if err != nil {
		return nil, err
	}
	consumesDir := filepath.Join(dir, "consumes")
	var code, suites []listed
	for _, p := range own {
		rel, _ := filepath.Rel(dir, p.Dir)
		if rel == "consumes" || strings.HasPrefix(rel, "consumes"+string(filepath.Separator)) {
			suites = append(suites, p)
		} else if len(p.GoFiles) > 0 {
			code = append(code, p)
		}
	}
	entries, _ := os.ReadDir(consumesDir)
	for _, e := range entries {
		if e.IsDir() {
			r.Suites[e.Name()] = &suite{Referenced: []string{}, Missing: []string{}, Extra: []string{}, Imports: []string{}, ForbiddenImports: []string{}, Skips: []string{}, Constraints: []string{}, HostPaths: []string{}, ReadmeMissing: []string{}}
		}
	}

	args := []string{"-deps", "-export"}
	for _, p := range code {
		args = append(args, p.ImportPath)
	}
	deps, err := goList(dir, args...)
	if err != nil {
		return nil, err
	}
	var suitePaths []string
	for _, p := range suites {
		suitePaths = append(suitePaths, p.ImportPath)
	}
	if len(suitePaths) > 0 {
		more, err := goList(dir, append([]string{"-deps", "-export", "-test"}, suitePaths...)...)
		if err != nil {
			return nil, err
		}
		deps = append(deps, more...)
	}
	export := map[string]string{}
	module := map[string]string{}
	standard := map[string]bool{}
	for _, p := range deps {
		if strings.Contains(p.ImportPath, " ") {
			continue
		}
		if p.Export != "" {
			export[p.ImportPath] = p.Export
		}
		if p.Module != nil {
			module[p.ImportPath] = p.Module.Path
		}
		standard[p.ImportPath] = p.Standard
	}
	producerOf := func(pkgPath string) string {
		m := module[pkgPath]
		if m == "" || m == mainMod {
			return ""
		}
		return path.Base(m)
	}

	fset := token.NewFileSet()
	imp := importer.ForCompiler(fset, "gc", func(p string) (io.ReadCloser, error) {
		f, ok := export[p]
		if !ok {
			return nil, fmt.Errorf("no export data for %s", p)
		}
		return os.Open(f)
	})
	check := func(pkgPath, pkgDir string, names []string) (*types.Info, []*ast.File, error) {
		var files []*ast.File
		for _, n := range names {
			b, err := os.ReadFile(filepath.Join(pkgDir, n))
			if err != nil {
				return nil, nil, err
			}
			f, err := parser.ParseFile(fset, filepath.Join(pkgDir, n), b, parser.ParseComments)
			if err != nil {
				return nil, nil, err
			}
			files = append(files, f)
		}
		info := &types.Info{Uses: map[*ast.Ident]types.Object{}, Selections: map[*ast.SelectorExpr]*types.Selection{}}
		conf := types.Config{Importer: imp}
		if _, err := conf.Check(pkgPath, fset, files, info); err != nil {
			return nil, nil, fmt.Errorf("type-check %s: %v", pkgPath, err)
		}
		return info, files, nil
	}

	// objects returns the dependency objects an Info uses, keyed by qualified name.
	objects := func(info *types.Info) map[string]types.Object {
		out := map[string]types.Object{}
		add := func(o types.Object) {
			if o == nil || o.Pkg() == nil || producerOf(o.Pkg().Path()) == "" {
				return
			}
			if _, ok := o.(*types.PkgName); ok {
				return
			}
			out[qualified(o)] = o
		}
		for _, o := range info.Uses {
			add(o)
		}
		for _, s := range info.Selections {
			add(s.Obj())
		}
		return out
	}

	used := map[string]map[string]types.Object{}
	for _, p := range code {
		info, _, err := check(p.ImportPath, p.Dir, p.GoFiles)
		if err != nil {
			r.Errors = append(r.Errors, err.Error())
			continue
		}
		for name, o := range objects(info) {
			prod := producerOf(o.Pkg().Path())
			if used[prod] == nil {
				used[prod] = map[string]types.Object{}
			}
			used[prod][name] = o
		}
	}
	allowed := map[string]map[string]bool{}
	for prod, objs := range used {
		allowed[prod] = map[string]bool{}
		for name, o := range objs {
			r.Used[prod] = append(r.Used[prod], name)
			allowed[prod][name] = true
			for _, tn := range namedIn(o.Type(), map[types.Type]bool{}) {
				if tn.Pkg() != nil && producerOf(tn.Pkg().Path()) == prod {
					allowed[prod][qualified(tn)] = true
				}
			}
		}
		sort.Strings(r.Used[prod])
	}

	byDir := map[string]listed{}
	for _, p := range suites {
		rel, _ := filepath.Rel(consumesDir, p.Dir)
		byDir[strings.Split(rel, string(filepath.Separator))[0]] = p
	}
	for name, s := range r.Suites {
		sdir := filepath.Join(consumesDir, name)
		if b, err := os.ReadFile(filepath.Join(sdir, "README.md")); err == nil {
			s.Readme = true
			for _, u := range r.Used[name] {
				if !bytes.Contains(b, []byte("${'`'}"+u+"${'`'}")) {
					s.ReadmeMissing = append(s.ReadmeMissing, u)
				}
			}
		} else {
			s.ReadmeMissing = append(s.ReadmeMissing, r.Used[name]...)
		}
		_ = filepath.WalkDir(sdir, func(p string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return err
			}
			b, err := os.ReadFile(p)
			if err == nil && hostPath.Match(b) {
				rel, _ := filepath.Rel(dir, p)
				s.HostPaths = append(s.HostPaths, filepath.ToSlash(rel))
			}
			return nil
		})
		p, ok := byDir[name]
		if !ok {
			r.Errors = append(r.Errors, "consumes/"+name+" is not a Go package")
			continue
		}
		for _, n := range p.IgnoredGoFiles {
			s.Constraints = append(s.Constraints, n)
		}
		groups := [][]string{append(append([]string{}, p.GoFiles...), p.TestGoFiles...), p.XTestGoFiles}
		refs := map[string]bool{}
		imports := map[string]bool{}
		for _, g := range groups {
			if len(g) == 0 {
				continue
			}
			s.Files += len(g)
			info, files, err := check(p.ImportPath+"_test", p.Dir, g)
			if err != nil {
				r.Errors = append(r.Errors, err.Error())
				continue
			}
			for qn, o := range objects(info) {
				if producerOf(o.Pkg().Path()) == name {
					refs[qn] = true
				}
			}
			for _, f := range files {
				fname := filepath.Base(fset.Position(f.Package).Filename)
				for _, cg := range f.Comments {
					if cg.Pos() > f.Package {
						break
					}
					for _, c := range cg.List {
						if strings.HasPrefix(c.Text, "//go:build") || strings.HasPrefix(c.Text, "// +build") {
							s.Constraints = append(s.Constraints, fname)
						}
					}
				}
				for _, is := range f.Imports {
					ip := strings.Trim(is.Path.Value, ${'`'}"${'`'})
					imports[ip] = true
				}
				for _, d := range f.Decls {
					if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv == nil && strings.HasPrefix(fd.Name.Name, "Test") && fd.Name.Name != "TestMain" {
						s.Tests++
					}
				}
				ast.Inspect(f, func(n ast.Node) bool {
					sel, ok := n.(*ast.SelectorExpr)
					if !ok {
						return true
					}
					if obj, ok := info.Selections[sel]; ok && obj.Obj().Pkg() != nil && obj.Obj().Pkg().Path() == "testing" {
						switch sel.Sel.Name {
						case "Skip", "Skipf", "SkipNow":
							pos := fset.Position(sel.Pos())
							s.Skips = append(s.Skips, fmt.Sprintf("%s:%d", filepath.Base(pos.Filename), pos.Line))
						}
					}
					return true
				})
			}
		}
		for ip := range imports {
			s.Imports = append(s.Imports, ip)
			if !standard[ip] && producerOf(ip) == "" {
				s.ForbiddenImports = append(s.ForbiddenImports, ip)
			}
		}
		for qn := range refs {
			s.Referenced = append(s.Referenced, qn)
			if !allowed[name][qn] {
				s.Extra = append(s.Extra, qn)
			}
		}
		for _, u := range r.Used[name] {
			if !refs[u] {
				s.Missing = append(s.Missing, u)
			}
		}
		for _, l := range [][]string{s.Referenced, s.Extra, s.Missing, s.Imports, s.ForbiddenImports, s.Skips, s.Constraints, s.HostPaths} {
			sort.Strings(l)
		}
	}
	return r, nil
}

// qualified names a dependency object as kogen code spells it: pkg.Name for package-level
// objects, pkg.Type.Field for struct fields and pkg.Type.Method for methods.
func qualified(o types.Object) string {
	pkg := o.Pkg().Name()
	switch x := o.(type) {
	case *types.Func:
		if sig, ok := x.Type().(*types.Signature); ok && sig.Recv() != nil {
			return pkg + "." + typeName(sig.Recv().Type()) + "." + x.Name()
		}
	case *types.Var:
		if x.IsField() {
			return pkg + "." + fieldOwner(x) + "." + x.Name()
		}
	}
	return pkg + "." + o.Name()
}

func typeName(t types.Type) string {
	if p, ok := t.(*types.Pointer); ok {
		t = p.Elem()
	}
	if n, ok := t.(*types.Named); ok {
		return n.Obj().Name()
	}
	return t.String()
}

func fieldOwner(v *types.Var) string {
	scope := v.Pkg().Scope()
	for _, n := range scope.Names() {
		tn, ok := scope.Lookup(n).(*types.TypeName)
		if !ok {
			continue
		}
		if st, ok := tn.Type().Underlying().(*types.Struct); ok {
			for i := 0; i < st.NumFields(); i++ {
				if st.Field(i) == v {
					return n
				}
			}
		}
	}
	return "?"
}

// namedIn lists the named types a type mentions, through pointers, slices, arrays, maps,
// channels and signatures, without descending into a named type's own definition.
func namedIn(t types.Type, seen map[types.Type]bool) []*types.TypeName {
	if t == nil || seen[t] {
		return nil
	}
	seen[t] = true
	switch x := t.(type) {
	case *types.Named:
		return []*types.TypeName{x.Obj()}
	case *types.Alias:
		return append([]*types.TypeName{x.Obj()}, namedIn(types.Unalias(x), seen)...)
	case *types.Pointer:
		return namedIn(x.Elem(), seen)
	case *types.Slice:
		return namedIn(x.Elem(), seen)
	case *types.Array:
		return namedIn(x.Elem(), seen)
	case *types.Chan:
		return namedIn(x.Elem(), seen)
	case *types.Map:
		return append(namedIn(x.Key(), seen), namedIn(x.Elem(), seen)...)
	case *types.Signature:
		var out []*types.TypeName
		for _, tup := range []*types.Tuple{x.Params(), x.Results()} {
			for i := 0; i < tup.Len(); i++ {
				out = append(out, namedIn(tup.At(i).Type(), seen)...)
			}
		}
		return out
	}
	return nil
}
`,
};
