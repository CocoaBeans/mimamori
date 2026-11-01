import Foundation

/// What a highlighter needs to know about one language: its words and its punctuation.
/// Deliberately small; the goal is a readable diff, not a parser.
public struct SyntaxLanguage: Sendable, Hashable {
    enum Family: Sendable, Hashable {
        /// Ordinary source code, plus JSON and CSS, which only need a few tweaks.
        case code, json, css
        /// Keys and values: YAML, and TOML/INI/.env style `key = value`.
        case yaml, keyValue
        case markup, markdown
    }

    public private(set) var name: String
    let family: Family
    var keywords: Set<String> = []
    var types: Set<String> = []
    /// `Capitalized` identifiers read as type names.
    var capitalizedAreTypes = false
    /// Keywords and types are matched in lowercase (SQL, Dockerfile).
    var caseInsensitive = false
    var lineComments: [[Character]] = []
    /// A `#` comment starts only at the beginning of a line or after a space (shell, YAML),
    /// so `$#` and `${#array}` stay code.
    var hashCommentNeedsSpace = false
    var blockOpen: [Character] = []
    var blockClose: [Character] = []
    var quotes: Set<Character> = ["\"", "'"]
    /// Delimiters of strings that may span lines, longest first.
    var multilineStrings: [[Character]] = []
    /// Characters that introduce an attribute or annotation before a name: `@MainActor`, `#if`.
    var attributePrefixes: Set<Character> = []
    /// Rust's `#[derive(...)]` and `#![...]`.
    var bracketAttributes = false
    /// C preprocessor lines: `#include`, `#define`.
    var directives = false
    /// `$name`, `${...}`, `$(...)` in shells and makefiles.
    var variablePrefix: Character?
    /// Extra characters allowed in identifiers: `$` in JavaScript, `-` in CSS and shells.
    var identifierExtras: Set<Character> = []
    /// Rust lifetimes (`'a`) rather than character literals.
    var lifetimes = false
    var highlightsNumbers = true

    init(_ name: String, _ family: Family = .code) {
        self.name = name
        self.family = family
    }
}

private func words(_ text: String) -> Set<String> {
    Set(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
}

private func chars(_ text: String) -> [Character] { Array(text) }

extension SyntaxLanguage {
    static let swift: SyntaxLanguage = {
        var l = SyntaxLanguage("Swift")
        l.keywords = words("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open operator
        private precedencegroup protocol public rethrows static struct subscript typealias var break case catch
        continue default defer do else fallthrough for guard if in repeat return throw switch where while as await
        async false is nil self Self super throws true try actor nonisolated isolated some any mutating nonmutating
        override final required convenience lazy weak unowned get set willSet didSet consuming borrowing sending
        macro package indirect
        """)
        l.types = words("Int Double Float String Bool Character Void Any AnyObject")
        l.capitalizedAreTypes = true
        l.lineComments = [chars("//")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        l.quotes = ["\""]
        l.multilineStrings = [chars("\"\"\"")]
        l.attributePrefixes = ["@", "#"]
        l.identifierExtras = ["$"]   // closure arguments: $0, $1
        return l
    }()

    static let python: SyntaxLanguage = {
        var l = SyntaxLanguage("Python")
        l.keywords = words("""
        False None True and as assert async await break class continue def del elif else except finally for from
        global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls
        """)
        l.types = words("int str float bool list dict set tuple bytes object type")
        l.capitalizedAreTypes = true
        l.lineComments = [chars("#")]
        l.multilineStrings = [chars("\"\"\""), chars("'''")]
        l.attributePrefixes = ["@"]
        return l
    }()

    static let javascript: SyntaxLanguage = {
        var l = SyntaxLanguage("JavaScript")
        l.keywords = words("""
        break case catch class const continue debugger default delete do else export extends false finally for
        function if import in instanceof new null return super switch this throw true try typeof var void while
        with yield let static async await of undefined from get set
        """)
        l.capitalizedAreTypes = true
        l.lineComments = [chars("//")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        l.multilineStrings = [chars("`")]
        l.attributePrefixes = ["@"]
        l.identifierExtras = ["$"]
        return l
    }()

    static let typescript: SyntaxLanguage = {
        var l = javascript
        l = SyntaxLanguage("TypeScript", l)
        l.keywords.formUnion(words("""
        enum implements interface package private protected public type namespace declare abstract readonly as is
        keyof infer never unknown any satisfies override
        """))
        l.types = words("string number boolean object symbol bigint void never unknown any")
        return l
    }()

    static let go: SyntaxLanguage = {
        var l = SyntaxLanguage("Go")
        l.keywords = words("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map
        package range return select struct switch type var true false nil iota
        """)
        l.types = words("""
        bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8
        uint16 uint32 uint64 uintptr any comparable
        """)
        l.lineComments = [chars("//")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        l.multilineStrings = [chars("`")]
        return l
    }()

    static let rust: SyntaxLanguage = {
        var l = SyntaxLanguage("Rust")
        l.keywords = words("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod
        move mut pub ref return self Self static struct super trait true type unsafe use where while
        """)
        l.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        l.capitalizedAreTypes = true
        l.lineComments = [chars("//")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        l.bracketAttributes = true
        l.lifetimes = true
        return l
    }()

    static let ruby: SyntaxLanguage = {
        var l = SyntaxLanguage("Ruby")
        l.keywords = words("""
        BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module
        next nil not or redo rescue retry return self super then true undef unless until when while yield require
        require_relative attr_accessor attr_reader attr_writer private protected public lambda proc
        """)
        l.capitalizedAreTypes = true
        l.lineComments = [chars("#")]
        l.attributePrefixes = ["@"]
        return l
    }()

    static let java: SyntaxLanguage = {
        var l = SyntaxLanguage("Java")
        l.keywords = words("""
        abstract assert boolean break byte case catch char class const continue default do double else enum
        extends final finally float for goto if implements import instanceof int interface long native new package
        private protected public return short static strictfp super switch synchronized this throw throws transient
        try void volatile while true false null var record sealed permits yield
        """)
        l.capitalizedAreTypes = true
        l.lineComments = [chars("//")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        l.multilineStrings = [chars("\"\"\"")]
        l.attributePrefixes = ["@"]
        return l
    }()

    static let kotlin: SyntaxLanguage = {
        var l = SyntaxLanguage("Kotlin", java)
        l.keywords = words("""
        as break class continue do else false for fun if in interface is null object package return super this
        throw true try typealias typeof val var when while by catch constructor finally get import init set where
        abstract annotation companion const crossinline data enum external final infix inline inner internal
        lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg
        """)
        return l
    }()

    static let cFamily: SyntaxLanguage = {
        var l = SyntaxLanguage("C")
        l.keywords = words("""
        auto break case char const continue default do double else enum extern float for goto if inline int long
        register restrict return short signed sizeof static struct switch typedef union unsigned void volatile
        while bool true false NULL nullptr class namespace template typename public private protected virtual
        override final new delete this throw try catch using operator friend explicit constexpr noexcept
        static_cast dynamic_cast reinterpret_cast const_cast decltype mutable thread_local concept requires
        """)
        l.types = words("size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t")
        l.lineComments = [chars("//")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        l.directives = true
        return l
    }()

    static let objectiveC: SyntaxLanguage = {
        var l = SyntaxLanguage("Objective-C", cFamily)
        l.keywords.formUnion(words("self super nil Nil YES NO id instancetype"))
        l.capitalizedAreTypes = true
        l.attributePrefixes = ["@"]
        return l
    }()

    static let csharp: SyntaxLanguage = {
        var l = SyntaxLanguage("C#")
        l.keywords = words("""
        abstract as base bool break byte case catch char checked class const continue decimal default delegate do
        double else enum event explicit extern false finally fixed float for foreach goto if implicit in int
        interface internal is lock long namespace new null object operator out override params private protected
        public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true
        try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var async await get set init
        record yield where nameof dynamic
        """)
        l.capitalizedAreTypes = true
        l.lineComments = [chars("//")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        l.directives = true
        return l
    }()

    static let shell: SyntaxLanguage = {
        var l = SyntaxLanguage("Shell")
        l.keywords = words("""
        if then else elif fi for while until do done case esac function in return local export readonly declare
        unset shift exit break continue source alias select time
        """)
        l.lineComments = [chars("#")]
        l.hashCommentNeedsSpace = true
        l.variablePrefix = "$"
        l.identifierExtras = ["-"]
        return l
    }()

    static let sql: SyntaxLanguage = {
        var l = SyntaxLanguage("SQL")
        l.keywords = words("""
        select from where and or not insert into values update set delete create table alter drop index view join
        left right inner outer full cross on as group by order having limit offset union all distinct case when then
        else end is null like ilike in between exists primary key foreign references default unique check
        constraint begin commit rollback transaction returning with recursive asc desc cascade if replace trigger
        function procedure declare true false
        """)
        l.types = words("""
        int integer bigint smallint text varchar char boolean bool date time timestamp timestamptz numeric decimal
        real double float serial bigserial uuid json jsonb blob
        """)
        l.caseInsensitive = true
        l.lineComments = [chars("--")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        return l
    }()

    static let dockerfile: SyntaxLanguage = {
        var l = SyntaxLanguage("Dockerfile")
        l.keywords = words("""
        from run cmd label expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck
        shell as maintainer
        """)
        l.caseInsensitive = true
        l.lineComments = [chars("#")]
        l.hashCommentNeedsSpace = true
        l.variablePrefix = "$"
        return l
    }()

    static let makefile: SyntaxLanguage = {
        var l = SyntaxLanguage("Makefile")
        l.keywords = words("ifeq ifneq ifdef ifndef else endif include define endef export override")
        l.lineComments = [chars("#")]
        l.variablePrefix = "$"
        return l
    }()

    static let json: SyntaxLanguage = {
        var l = SyntaxLanguage("JSON", Family.json)
        l.keywords = words("true false null")
        l.quotes = ["\""]
        l.lineComments = [chars("//")]
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        return l
    }()

    static let yaml: SyntaxLanguage = {
        var l = SyntaxLanguage("YAML", Family.yaml)
        l.keywords = words("true false null yes no on off True False Null TRUE FALSE NULL ~")
        l.lineComments = [chars("#")]
        l.hashCommentNeedsSpace = true
        l.attributePrefixes = ["&", "*", "!"]
        return l
    }()

    static let toml: SyntaxLanguage = {
        var l = SyntaxLanguage("TOML", Family.keyValue)
        l.keywords = words("true false export")
        l.lineComments = [chars("#"), chars(";")]
        l.hashCommentNeedsSpace = true
        l.multilineStrings = [chars("\"\"\""), chars("'''")]
        l.variablePrefix = "$"
        return l
    }()

    static let markup: SyntaxLanguage = {
        var l = SyntaxLanguage("HTML", Family.markup)
        l.highlightsNumbers = false
        return l
    }()

    static let markdown: SyntaxLanguage = {
        var l = SyntaxLanguage("Markdown", Family.markdown)
        l.highlightsNumbers = false
        return l
    }()

    static let css: SyntaxLanguage = {
        var l = SyntaxLanguage("CSS", Family.css)
        l.keywords = words("important inherit initial unset none auto")
        l.blockOpen = chars("/*"); l.blockClose = chars("*/")
        l.attributePrefixes = ["@"]
        l.identifierExtras = ["-"]
        return l
    }()

    static let scss: SyntaxLanguage = {
        var l = SyntaxLanguage("SCSS", css)
        l.lineComments = [chars("//")]
        l.variablePrefix = "$"
        return l
    }()

    /// `.gitignore` and friends: only comments are worth a color.
    static let ignoreFile: SyntaxLanguage = {
        var l = SyntaxLanguage("Ignore file")
        l.quotes = []
        l.lineComments = [chars("#")]
        l.highlightsNumbers = false
        return l
    }()

    /// A copy of `base` under another name.
    init(_ name: String, _ base: SyntaxLanguage) {
        self = base
        self.name = name
    }
}

extension SyntaxLanguage {
    private static let byExtension: [String: SyntaxLanguage] = {
        var map: [String: SyntaxLanguage] = [:]
        func add(_ language: SyntaxLanguage, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = language }
        }
        add(.swift, "swift")
        add(.python, "py pyw pyi")
        add(.javascript, "js jsx mjs cjs")
        add(.typescript, "ts tsx mts cts")
        add(.go, "go")
        add(.rust, "rs")
        add(.ruby, "rb rake gemspec")
        add(.java, "java")
        add(.kotlin, "kt kts")
        add(.cFamily, "c h cpp cc cxx hpp hh hxx")
        add(.objectiveC, "m mm")
        add(.csharp, "cs")
        add(.shell, "sh bash zsh fish command")
        add(.sql, "sql")
        add(.dockerfile, "dockerfile")
        add(.makefile, "mk mak")
        add(.json, "json jsonc json5 geojson webmanifest")
        add(.yaml, "yml yaml")
        add(.toml, "toml ini cfg conf properties env")
        add(.markup, "html htm xhtml xml plist svg xib storyboard xcscheme entitlements")
        add(.markdown, "md markdown mdx")
        add(.css, "css")
        add(.scss, "scss sass less")
        return map
    }()

    private static let byFileName: [String: SyntaxLanguage] = [
        "Dockerfile": .dockerfile, "Containerfile": .dockerfile,
        "Makefile": .makefile, "makefile": .makefile, "GNUmakefile": .makefile,
        "Gemfile": .ruby, "Rakefile": .ruby, "Podfile": .ruby, "Fastfile": .ruby, "Brewfile": .ruby,
        ".gitignore": .ignoreFile, ".gitattributes": .ignoreFile, ".dockerignore": .ignoreFile,
        ".npmignore": .ignoreFile, ".gitmodules": .toml, ".editorconfig": .toml,
        ".zshrc": .shell, ".bashrc": .shell, ".bash_profile": .shell, ".zprofile": .shell, ".profile": .shell,
    ]

    /// The language of a file, from its name or extension; nil when Mimamori does not know it.
    public static func forPath(_ path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent
        if let known = byFileName[name] { return known }
        if name.hasPrefix(".env") { return .toml }
        if name.hasPrefix("Dockerfile.") { return .dockerfile }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : byExtension[ext]
    }
}
