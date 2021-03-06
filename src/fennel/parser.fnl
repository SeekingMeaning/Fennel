(local utils (require :fennel.utils))
(local friend (require :fennel.friend))
(local unpack (or _G.unpack table.unpack))

(fn granulate [getchunk]
  "Convert a stream of chunks to a stream of bytes.
Also returns a second function to clear the buffer in the byte stream"
  (var c "")
  (var index 1)
  (var done false)
  (values (fn [parserState]
            (when (not done)
              (if (<= index (# c))
                  (let [b (: c "byte" index)]
                    (set index (+ index 1))
                    b)
                  (do
                    (set c (getchunk parserState))
                    (when (or (not c) (= c ""))
                      (set done true)
                      (lua "return nil"))
                    (set index 2)
                    (: c "byte" 1)))))
          (fn [] (set c ""))))

(fn stringStream [str]
  "Convert a string into a stream of bytes."
  (let [str (: str "gsub" "^#![^\n]*\n" "")] ; remove shebang
    (var index 1)
    (fn [] (local r (: str "byte" index))
      (set index (+ index 1))
      r)))

;; Table of delimiter bytes - (, ), [, ], {, }
;; Opener keys have closer as the value; closers keys have true as their value.
(local delims {40 41 41 true
               91 93 93 true
               123 125 125 true})

(fn iswhitespace [b]
  (or (= b 32) (and (>= b 9) (<= b 13))))

(fn issymbolchar [b]
  (and (> b 32)
       (not (. delims b))
       (not= b 127) ; backspace
       (not= b 34) ; backslash
       (not= b 39) ; single quote
       (not= b 126) ; tilde
       (not= b 59) ; semicolon
       (not= b 44) ; comma
       (not= b 64) ; at
       (not= b 96))) ; backtick

;; prefix chars substituted while reading
(local prefixes {35 "hashfn" ; #
                 39 "quote" ; '
                 44 "unquote" ; ,
                 96 "quote"}); `

(fn parser [getbyte filename options]
  "Parse one value given a function that returns sequential bytes.
Will throw an error as soon as possible without getting more bytes on bad input.
Returns if a value was read, and then the value read. Will return nil when input
stream is finished."
  (var stack []) ; stack of unfinished values
  ;; Provide one character buffer and keep track of current line and byte index
  (var line 1)
  (var byteindex 0)
  (var lastb nil)

  (fn ungetb [ub]
    (when (= ub 10)
      (set line (- line 1)))
    (set byteindex (- byteindex 1))
    (set lastb ub))

  (fn getb []
    (var r nil)
    (if lastb
        (set (r lastb) (values lastb nil))
        (set r (getbyte {:stackSize (# stack)})))
    (set byteindex (+ byteindex 1))
    (when (= r 10)
      (set line (+ line 1)))
    r)

  ;; If you add new calls to this function, please update fennel.friend as well
  ;; to add suggestions for how to fix the new error!
  (fn parseError [msg]
    (let [{: source : unfriendly} (or utils.root.options {})]
      (utils.root.reset)
      (if unfriendly
          (error (: "Parse error in %s:%s: %s" "format" (or filename "unknown")
                    (or line "?") msg) 0)
          (friend.parse-error msg (or filename "unknown") (or line "?")
                              byteindex source))))

  (fn parseStream []
    (var (whitespaceSinceDispatch done retval) true)
    (fn dispatch [v]
      "Dispatch when we complete a value"
      (if (= (# stack) 0)
          (do
            (set retval v)
            (set done true)
            (set whitespaceSinceDispatch false))
          (. (. stack (# stack)) "prefix")
          (do
            (local stacktop (. stack (# stack)))
            (tset stack (# stack) nil)
            (dispatch (utils.list (utils.sym stacktop.prefix) v)))
          (do
            (set whitespaceSinceDispatch false)
            (table.insert (. stack (# stack)) v))))

    (fn badend []
      "Throw nice error when we expect more characters but reach end of stream."
      (let [accum (utils.map stack "closer")]
        (parseError (: "expected closing delimiter%s %s" :format
                       (or (and (= (# stack) 1) "") "s")
                       (string.char (unpack accum))))))
    (while true ; main parse loop
      (var b nil)
      (while true ; skip whitespace
        (set b (getb))
        (when (and b (iswhitespace b))
          (set whitespaceSinceDispatch true))
        (when (or (not b) (not (iswhitespace b)))
          (lua "break")))

      (when (not b)
        (when (> (# stack) 0)
          (badend))
        (lua "return nil"))

      (if (= b 59) ; comment
          (while true
            (set b (getb))
            (when (or (not b) (= b 10))
              (lua "break")))
          (= (type (. delims b)) :number) ; opening delimiter
          (do
            (when (not whitespaceSinceDispatch)
              (parseError (.. "expected whitespace before opening delimiter "
                              (string.char b))))
            (table.insert stack (setmetatable {:bytestart byteindex
                                               :closer (. delims b)
                                               :filename filename
                                               :line line}
                                              (getmetatable (utils.list)))))
          (. delims b) ; closing delimiter
          (do
            (when (= (# stack) 0)
              (parseError (.. "unexpected closing delimiter " (string.char b))))
            (local last (. stack (# stack)))
            (var val (values))
            (when (not= last.closer b)
              (parseError (.. "mismatched closing delimiter " (string.char b)
                              ", expected " (string.char last.closer))))
            (set last.byteend byteindex) ; set closing byte index
            (if (= b 41)
                (set val last)
                (= b 93)
                (do
                  (set val (utils.sequence (unpack last)))
                  ;; for table literals we can store file/line/offset source
                  ;; data in fields on the table itself, because the AST node
                  ;; *is* the table, and the fields would show up in the
                  ;; compiled output. keep them on the metatable instead.
                  (each [k v (pairs last)]
                    (tset (getmetatable val) k v)))
                (do
                  (when (not= (% (# last) 2) 0)
                    (set byteindex (- byteindex 1))
                    (parseError "expected even number of values in table literal"))
                  (set val [])
                  (setmetatable val last) ; see note above about source data
                  (for [i 1 (# last) 2]
                    (when (and (= (tostring (. last i)) ":")
                               (utils.isSym (. last (+ i 1)))
                               (utils.isSym (. last i)))
                      (tset last i (tostring (. last (+ i 1)))))
                    (tset val (. last i) (. last (+ i 1))))))
            (tset stack (# stack) nil)
            (dispatch val))
          (= b 34) ; quoted string
          (do
            (var state "base")
            (local chars [34])
            (tset stack (+ (# stack) 1) {:closer 34})
            (while true
              (set b (getb))
              (tset chars (+ (# chars) 1) b)
              (if (= state "base")
                  (if (= b 92)
                      (set state "backslash")
                      (= b 34)
                      (set state "done"))
                  (set state "base"))
              (when (or (not b) (= state "done"))
                (lua "break")))
            (when (not b)
              (badend))
            (tset stack (# stack) nil)
            (let [raw (string.char (unpack chars))
                  formatted (raw:gsub "[\1-\31]" (fn [c] (.. "\\" (: c "byte"))))
                  loadFn ((or _G.loadstring load)
                          (: "return %s" :format formatted))]
              (dispatch (loadFn))))
          (. prefixes b)
          (do ; expand prefix byte into wrapping form eg. '`a' into '(quote a)'
            (table.insert stack {:prefix (. prefixes b)})
            (let [nextb (getb)]
              (when (iswhitespace nextb)
                (when (not= b 35)
                  (parseError "invalid whitespace after quoting prefix"))
                (tset stack (# stack) nil)
                (dispatch (utils.sym "#")))
              (ungetb nextb)))
          (or (issymbolchar b) (= b (string.byte "~"))) ; try sym
          (let [chars []
                bytestart byteindex]
            (while true
              (tset chars (+ (# chars) 1) b)
              (set b (getb))
              (when (or (not b) (not (issymbolchar b)))
                (lua "break")))
            (when b
              (ungetb b))
            (local rawstr (string.char (unpack chars)))
            (if (= rawstr "true")
                (dispatch true)
                (= rawstr "false")
                (dispatch false)
                (= rawstr "...")
                (dispatch (utils.varg))
                (: rawstr "match" "^:.+$")
                (dispatch (: rawstr "sub" 2))
                ;; for backwards-compatibility, special-case allowance
                ;; of ~= but all other uses of ~ are disallowed
                (and (rawstr:match "^~") (not= rawstr "~="))
                (parseError "illegal character: ~")
                (let [forceNumber (: rawstr "match" "^%d")
                      numberWithStrippedUnderscores (: rawstr "gsub" "_" "")]
                  (var x nil)
                  (if forceNumber
                      (set x (or (tonumber numberWithStrippedUnderscores)
                                 (parseError (.. "could not read number \""
                                                 rawstr "\""))))
                      (do
                        (set x (tonumber numberWithStrippedUnderscores))
                        (when (not x)
                          (if (: rawstr "match" "%.[0-9]")
                              (do
                                (set byteindex (+ (+ (- byteindex (# rawstr))
                                                     (rawstr:find "%.[0-9]")) 1))
                                (parseError (.. "can't start multisym segment "
                                                "with a digit: " rawstr)))
                              (and (: rawstr "match" "[%.:][%.:]")
                                   (not= rawstr "..")
                                   (not= rawstr "$..."))
                              (do
                                (set byteindex (+ (- byteindex (# rawstr)) 1
                                                  (: rawstr "find" "[%.:][%.:]")))
                                (parseError (.. "malformed multisym: " rawstr)))
                              (rawstr:match ":.+[%.:]")
                              (do
                                (set byteindex (+ (- byteindex (# rawstr))
                                                  (: rawstr "find" ":.+[%.:]")))
                                (parseError (.. "method must be last component "
                                                "of multisym: " rawstr)))
                              (set x (utils.sym rawstr nil {:byteend byteindex
                                                            :bytestart bytestart
                                                            :filename filename
                                                            :line line}))))))
                  (dispatch x))))
          (parseError (.. "illegal character: " (string.char b))))
      (when done
        (lua "break")))
    (values true retval))
  (values parseStream (fn [] (set stack []))))

{: granulate : parser : stringStream}
