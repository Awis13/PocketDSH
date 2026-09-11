import Foundation

public enum ShellFrame: Sendable, Equatable {
    case output(Data)
    case workspace(String)
    case start(command: String, directory: String)
    case ready(code: Int, directory: String)
    case completion(id: String, values: [String], limited: Bool)
    /// An oversized marker was abandoned by the bounded framing buffer, so at
    /// least one lifecycle marker never became a frame. The associated count is
    /// the number of bytes flushed as output, never a marker identity. This is
    /// the only point where a marker loss is knowable, so a consumer that pairs
    /// markers across frames must invalidate any open pair when it sees one.
    case dropped(count: Int)
}

/// Incremental framing only. Ordinary ANSI remains untouched for the emulator.
/// Markers describe display lifecycle; they never grant execution authority.
public struct ShellFrameParser: Sendable {
    private let prefix: Data
    private var pending = Data()
    public init(nonce: String) { prefix = Data("\u{1b}P+h;\(nonce);".utf8) }
    public mutating func feed(_ data: Data) -> [ShellFrame] {
        pending.append(data)
        var result: [ShellFrame] = []
        while !pending.isEmpty {
            if let range = pending.range(of: prefix) {
                if range.lowerBound > pending.startIndex {
                    result.append(.output(Data(pending[..<range.lowerBound])))
                    pending = Data(pending[range.lowerBound...])
                }
                guard let end = pending.range(of: Data([27, 92]), in: prefix.count..<pending.count) else {
                    if pending.count > 131072 { result.append(.output(pending)); result.append(.dropped(count: pending.count)); pending.removeAll() }
                    break
                }
                let body = String(decoding: pending[prefix.count..<end.lowerBound], as: UTF8.self)
                let raw = Data(pending[..<end.upperBound])
                pending = Data(pending[end.upperBound...])
                let fields = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                if fields.count == 4, fields[0] == "C", UUID(uuidString: fields[1]) != nil,
                   let bytes = Data(base64Encoded: fields[3]), let text = String(data: bytes, encoding: .utf8) {
                    result.append(.completion(id: fields[1], values: Array(text.split(separator: "\0").map(String.init).prefix(100)), limited: fields[2] == "1"))
                    continue
                }
                if fields.count == 2, fields[0] == "A", let bytes = Data(base64Encoded: fields[1]), let action = String(data: bytes, encoding: .utf8),
                   ["split right", "split down", "focus next", "focus previous", "maximize", "close", "view chat", "view terminal"].contains(action) {
                    result.append(.workspace(action)); continue
                }
                if fields.count == 3, let cwd = Data(base64Encoded: fields[2]), let directory = String(data: cwd, encoding: .utf8) {
                    if fields[0] == "S", let c = Data(base64Encoded: fields[1]), let command = String(data: c, encoding: .utf8) {
                        result.append(.start(command: command, directory: directory)); continue
                    }
                    if fields[0] == "E", let code = Int(fields[1]) {
                        result.append(.ready(code: code, directory: directory)); continue
                    }
                }
                result.append(.output(raw))
            } else {
                // Retain a possible marker prefix split across reads.
                var keep = min(prefix.count - 1, pending.count)
                while keep > 0 && pending.suffix(keep) != prefix.prefix(keep) { keep -= 1 }
                if pending.count > keep { result.append(.output(Data(pending.prefix(pending.count - keep)))) }
                pending = Data(pending.suffix(keep)); break
            }
        }
        return result
    }
    public mutating func finish() -> [ShellFrame] {
        defer { pending.removeAll() }
        return pending.isEmpty ? [] : [.output(pending)]
    }
}

/// Private per-session startup file; never edits the user's shell configuration.
final class ShellIntegration {
    let directory: URL
    let nonce = UUID().uuidString
    private let lock = NSLock()
    private var pending: (id: String, result: ShellCompletions?)?
    var completionKey: Data { Data("\u{1b}[harness-\(nonce)~".utf8) }
    func beginCompletion(token: String, kind: String) throws -> String {
        try lock.withLock {
            guard pending == nil else { throw HarnessError.invalid("Completion already pending") }
            let id = UUID().uuidString
            let text = id + "\n" + kind + "\n" + Data(token.utf8).base64EncodedString() + "\n"
            try text.write(to: directory.appendingPathComponent("completion"), atomically: true, encoding: .utf8)
            pending = (id, nil)
            return id
        }
    }
    func resolve(id: String, values: [String], limited: Bool) {
        lock.withLock { if pending?.id == id { pending?.result = ShellCompletions(values: values, limited: limited) } }
    }
    func result(id: String) -> ShellCompletions? { lock.withLock { pending?.id == id ? pending?.result : nil } }
    func cancel(id: String) { lock.withLock { if pending?.id == id { pending = nil } } }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = """
        unset ZDOTDIR
        unsetopt GLOBAL_RCS
        PROMPT='%F{magenta}❯%f '
        RPROMPT=''
        PROMPT_EOL_MARK=''
        export COLORTERM=truecolor
        function __harness_preexec() {
          builtin printf '\\033P+h;\(nonce);S;%s;%s\\033\\\\' "$(builtin printf '%s' "$1" | /usr/bin/base64)" "$(builtin printf '%s' "$PWD" | /usr/bin/base64)"
        }
        function __harness_precmd() {
          local result=$?
          builtin printf '\\033P+h;\(nonce);E;%s;%s\\033\\\\' "$result" "$(builtin printf '%s' "$PWD" | /usr/bin/base64)"
        }
        function harness-ui() {
          builtin printf '\\033P+h;\(nonce);A;%s\\033\\\\' "$(builtin printf '%s' "$*" | /usr/bin/base64)"
        }
        preexec_functions=(__harness_preexec)
        precmd_functions=(__harness_precmd)
        \(listingScript)
        \(completionScript)
        """
        try script.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    // Interactive conveniences only; scripts, pipes and unsupported ls flags
    // retain the platform ls contract. Arguments are arrays, never shell code.
    private var listingScript: String {
        #"""
        export EZA_COLORS='di=1;34:ex=1;32:ln=36:or=1;31:ur=33:uw=31:ux=32:ue=32:gr=33:gw=31:gx=32:tr=33:tw=31:tx=32:sn=36:sb=2;36:da=2;37:uu=35:gu=2;35:xx=2;37:hd=1;4;37:ga=32:gm=33:gd=31:gv=36:gi=2;37:gc=1;31'
        function __harness_eza() {
          command eza --color=auto --icons=auto --group-directories-first "$@"
        }
        function ls() {
          emulate -L zsh
          if [[ ! -t 1 || ${HARNESS_EZA:-1} == 0 ]] || ! (( $+commands[eza] )); then
            command ls "$@"; return
          fi
          local arg flag
          local -a options paths
          local -i end_options=0 long=0
          for arg in "$@"; do
            if (( end_options )); then paths+=( "$arg" ); continue; fi
            case "$arg" in
              --) end_options=1 ;;
              -*)
                # Only this shared subset is translated. In particular, eza's
                # -h and -t mean different things from the platform ls flags.
                if [[ $arg == - || $arg == --* || ${arg[2,-1]} == *[^laAhrd1F]* ]]; then
                  command ls "$@"; return
                fi
                for flag in ${(s::)arg[2,-1]}; do
                  case "$flag" in
                    h) ;; # eza already formats sizes in human-readable units
                    l) long=1; options+=( -l ) ;;
                    *) options+=( "-$flag" ) ;;
                  esac
                done ;;
              *) paths+=( "$arg" ) ;;
            esac
          done
          (( long )) && options+=( --header --git )
          __harness_eza "${options[@]}" -- "${paths[@]}"
        }
        function ll() {
          if (( $+commands[eza] )); then __harness_eza --long --header --git "$@"
          else command ls -lh "$@"; fi
        }
        function la() {
          if (( $+commands[eza] )); then __harness_eza --long --all --header --git "$@"
          else command ls -lah "$@"; fi
        }
        function lt() {
          if (( $+commands[eza] )); then __harness_eza --tree --level=2 "$@"
          else command ls -R "$@"; fi
        }
        """#
    }

    // A ZLE widget reads data, never evaluates the draft or accepts a shell line.
    // Lookup runs inside the actual shell, including its aliases, PATH and cwd.
    private var completionScript: String {
        #"""
        function __harness_complete() {
          emulate -L zsh
          local rid kind encoded token candidate name search base dir lead value variable
          local -a matches paths names
          local -i limited=0 size=0
          { IFS= read -r rid; IFS= read -r kind; IFS= read -r encoded; } < '\#(directory.path)/completion' || return
          token=$(builtin printf '%s' "$encoded" | /usr/bin/base64 -D)
          if [[ $kind == command && $token != */* && $token != '~'* && $token != '$'* ]]; then
            zmodload zsh/parameter
            names=( ${(k)commands} ${(k)builtins} ${(k)aliases} ${(k)functions} )
            for name in ${(ou)names}; do
              [[ $name == __harness_* ]] && continue
              [[ -z $token || ${name[1,${#token}]} == "$token" ]] || continue
              matches+=( "$name" )
              (( ${#matches} >= 100 )) && { limited=1; break; }
            done
          fi
          search=$token
          if [[ $search == '~/'* ]]; then
            search="$HOME/${search[3,-1]}"
          elif [[ $search == '$'* && $search == */* ]]; then
            variable=${search%%/*}; variable=${variable[2,-1]}
            if [[ $variable =~ '^[A-Za-z_][A-Za-z0-9_]*$' && ${+parameters[$variable]} == 1 ]]; then
              search="${(P)variable}/${search#*/}"
            fi
          fi
          if [[ $search == */* ]]; then dir=${search%/*}; base=${search##*/}; [[ -n $dir ]] || dir=/
          else dir=.; base=$search; fi
          if [[ $token == */* ]]; then lead=${token%/*}/; else lead=''; fi
          paths=( "$dir"/*(ND) )
          for candidate in $paths; do
            name=${candidate:t}
            [[ -z $base || ${name[1,${#base}]} == "$base" ]] || continue
            [[ $name != .* || $base == .* ]] || continue
            [[ $kind != directory || -d $candidate ]] || continue
            if [[ $kind == command ]]; then
              [[ $token == */* || $token == .* ]] || continue
              [[ -d $candidate || -x $candidate ]] || continue
            fi
            value="$lead$name"
            [[ -d $candidate ]] && value+=/
            (( size += ${#value} ))
            if (( ${#matches} >= 100 || size > 24000 )); then limited=1; break; fi
            matches+=( "$value" )
          done
          local payload=''
          if (( ${#matches} )); then payload=$(builtin printf '%s\0' "${(@ou)matches}" | /usr/bin/base64); fi
          builtin printf '\033P+h;\#(nonce);C;%s;%s;%s\033\\' "$rid" "$limited" "$payload"
        }
        zle -N __harness_complete
        bindkey '\e[harness-\#(nonce)~' __harness_complete
        """#
    }
}

public struct ShellCompletions: Sendable, Equatable {
    public let values: [String]
    public let limited: Bool
}
