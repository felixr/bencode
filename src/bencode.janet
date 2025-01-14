#
# Provides functions for decoding data in the bencode format.
#

# Special ASCII characters use during parsing
(def- NEW-LINE 10)
(def- CARRIAGE-RETURN 13)
(def- MINUS 45)
(def- LENGTH-SEPARATOR 58)
(def- DICTIONARY-FLAG 100)
(def- END-FLAG 101)
(def- INT-FLAG 105)
(def- LIST-FLAG 108)

(defn- parse-error
  "Throws an error with the provided message for the given reader, the error
  will include the index of the reader."
  [message &opt reader-in]
  (if reader-in
    (error (string message " at index " (reader-in :index)))
    (error (string message))))

(defn- write-error
  "Throws an error with the provided message for the given data object"
  [message &opt data]
  (if data
    (error (string message " when writing data of type " (type data)))
    (error (string message))))

(defn- peek-byte
  "Returns the byte at the reader's current index"
  [reader-in]
  (let [byte (get (reader-in :buffer) (reader-in :index))]
    byte))

(defn- end?
  "Returns true if the index points to the end of the buffer"
  [reader-in]
  (if (nil? (peek-byte reader-in))
    true false))

(defn- read-byte-buffer
  "Returns the byte at the reader's current index and advances the index"
  [reader-in]
  (if (end? reader-in)
    (error "Read past the end of the buffer")
    (let [input (peek-byte reader-in)]
      (put reader-in :index (+ (reader-in :index) 1))
      input)))

(defn- read-byte-stream
  "Reads another byte from the stream, appends it to the buffer for the reader,
  increments the index and returns that byte"
  [reader-stream-in]
  (if (end? reader-stream-in)
    (error "The stream has been closed")
    (let [input (get (reader-stream-in :buffer) (reader-stream-in :index))]
      (net/read (reader-stream-in :stream) 1 (reader-stream-in :buffer))
      (put reader-stream-in :index (+ (reader-stream-in :index) 1))
      input)))

(defn- read-byte
  "Reads the next byte from the provided reader. If the reader is wrapping a
  network stream, this function will block until a byte is available to read"
  [reader-in]
  (if (reader-in :stream)
    (read-byte-stream reader-in)
    (read-byte-buffer reader-in)))

(defn- match-byte
  "If the reader's next byte  matches the provided byte, advances the reader"
  [reader-in byte]
  (if (= byte (peek-byte reader-in)) 
    (read-byte reader-in)
    false))

(defn- digit-byte?
  "Returns true if the provided byte represents a digit"
  [byte]
  (if (and (< 47 byte) (> 58 byte)) true false))

(defn clear-reader
  "Clears a reader by dropping all of the read data from the buffer and
  resetting the index"
  [reader-in]
  (if (reader-in :stream)
    @{:index 0
      :buffer (buffer/slice (reader-in :buffer) -1)
      :stream (reader-in :stream)}
    @{:index 0
      :buffer (buffer/slice (reader-in :buffer) -1)}))

(defn advance-clear-reader
  [reader-in]
  (read-byte reader-in)
  (clear-reader reader-in))

(defn- read-integer-bytes
  "Reads the next integer from the buffer

  The integer may include a minus indicating sign, we simply keep reading bytes
  as long as they represent a digit."
  [reader-in]
  (let [buffer-out (buffer/new 0)]

    # check to see if the number is signed
    (if (= MINUS (peek-byte reader-in))
      (buffer/push-byte buffer-out (read-byte reader-in)))

    # make sure we have at least one digit
    (if-not (digit-byte? (peek-byte reader-in))
      (parse-error "No digits for integer" reader-in))

    # read all of the digits
    (while (digit-byte? (peek-byte reader-in))
      (buffer/push-byte buffer-out (read-byte reader-in)))
    (scan-number buffer-out)))

(defn- read-integer
  "Reads a bencoded integer from the reader"
  [reader-in]
  (if-not (match-byte reader-in INT-FLAG)
    (parse-error "No integer found" reader-in))
  (let [int-in (try (read-integer-bytes reader-in)
                    ([error] (parse-error
                              (string "Couldn't read integer: " error))))]
    (if-not (match-byte reader-in END-FLAG)
      (parse-error "Unterminated integer" reader-in))
    int-in))

(defn- read-string
  "Reads a bencoded binary string from the reader"
  [return-mutable reader-in]
  (if-not (digit-byte? (peek-byte reader-in))
    (parse-error "No length found for string" reader-in))

  (let [length (read-integer-bytes reader-in)
        buffer-out (buffer/new 0)]

    (if (> 0 length)
      (parse-error (string "String length cannot be less than zero (" length ")") reader-in))

    (if-not (match-byte reader-in LENGTH-SEPARATOR)
      (parse-error "No separator \":\" after string length" reader-in))

    (for count 0 length
      (buffer/push-byte buffer-out (read-byte reader-in)))
    (if return-mutable
      buffer-out
      (string buffer-out))))

(defn- read-list
  "Reads a list, using the read-bencode-fn to parse nested structures, from
  the reader"
  [read-bencode-fn return-mutable level reader-in]
  (if-not (match-byte reader-in LIST-FLAG)
    (parse-error "No list found" reader-in))
  (let [list-out (array/new 0)]
    (while (not (or (= END-FLAG (peek-byte reader-in))
                    (end? reader-in)))
      (let [token (read-bencode-fn reader-in)]
        (array/push list-out token)))
    (if (or (and (= level 0) (not= (peek-byte reader-in) END-FLAG))
            (and (> level 0) (not (match-byte reader-in END-FLAG))))
      (parse-error "Unterminated list" reader-in))
    (if return-mutable
      list-out
      (tuple ;list-out))))

(defn- read-dictionary
  "Reads a dictionary, using the read-bencode-fn to parse nested structures,
  from the reader"
  [read-bencode-fn keyword-dicts return-mutable level reader-in]
  (if-not (match-byte reader-in DICTIONARY-FLAG)
    (parse-error "No dictionary found" reader-in))
  (let [dict-out @{}]
    (while (not (or (= END-FLAG (peek-byte reader-in))
                    (end? reader-in)))
      (let [key-in (try (read-string return-mutable reader-in)
                        ([error] (parse-error
                                  (string "Couldn't read key: " error))))
            val-in (try (read-bencode-fn reader-in)
                        ([error] (parse-error
                                  (string "Couldn't read value: " error))))]
        (put dict-out
             (if keyword-dicts (keyword key-in) key-in)
             val-in)))
    (if (or (and (= level 0) (not= (peek-byte reader-in) END-FLAG))
            (and (> level 0) (not (match-byte reader-in END-FLAG))))
      (parse-error "Unterminated dictionary" reader-in))
    (if return-mutable
      dict-out
      (table/to-struct dict-out))))

(defn- peek-newline
  [reader-in]
  (if (or (= NEW-LINE (peek-byte reader-in))
          (= CARRIAGE-RETURN (peek-byte reader-in)))
    true false))

(defn- read-newlines
  "Reads one or more new lines from the reader"
  [reader-in]
  (while (and (not (end? reader-in))
             (peek-newline reader-in))
    (read-byte reader-in)
    (clear-reader reader-in))
  nil)

(defn- read-bencode
  "Reads the next bencoded value from the reader, returns null if there is no
  data left to read.

  If the keyword-dicts value is true, then the keys of dictionaries will be
  turned into keywords.

  If the ignore-newlines value is true, then new line characters in between
  bencoded values will be ignored.

  If the return-mutable value is true, then the result uses mutable data
  structures (the default is false)."
  [keyword-dicts ignore-newlines return-mutable level reader-in]
  (let [read-fn
        (partial read-bencode keyword-dicts ignore-newlines return-mutable (inc level))]
    (cond
      (end? reader-in)
      nil

      (and (peek-newline reader-in)
           ignore-newlines)
      (read-newlines reader-in)

      (= INT-FLAG (peek-byte reader-in))
      (read-integer reader-in)

      # strings begin with an integer indicating their length
      (digit-byte? (peek-byte reader-in))
      (read-string return-mutable reader-in)

      (= LIST-FLAG (peek-byte reader-in))
      (read-list read-fn return-mutable level reader-in)

      (= DICTIONARY-FLAG (peek-byte reader-in))
      (read-dictionary read-fn keyword-dicts return-mutable level reader-in)

      (parse-error (string "Unrecognized token \"" (peek-byte reader-in) "\"")
                   reader-in))))

(defn reader
  "Returns a \"reader\" for the buffer.

  A reader is a table with two keys...
    :index  a pointer to the next byte to be read
    :buffer the buffer being read"
  [buffer &opt index-in]
  (let [index (if-not (nil? index-in) index-in 0)]
    @{:index index :buffer buffer}))

(defn reader-stream
  "Returns a \"reader\" for the stream.

  A stream reader is a table with three keys...
    :index  a pointer to the next byte to be read
    :buffer the data read from the stream
    :stream the stream we're reading from"
  [stream]
  (let [buffer-in @""]
    (net/read stream 1 buffer-in)
    @{:index 0 :buffer buffer-in :stream stream}))

(defn read
  "Reads the next bencoded value from the reader, returns null if there is no
  data left to read.

  If the keyword-dicts value is true, then the keys of dictionaries will be
  turned into keywords (the default is true).

  If the ignore-newlines value is true, then new line characters in between the
  bencoded values will be ignored (the default is false).

  If the return-mutable value is true, then the result uses mutable data
  structures (the default is false)."
  [reader-in &keys {:keyword-dicts keyword-dicts
                    :ignore-newlines ignore-newlines
                    :return-mutable return-mutable}]
  (read-bencode
   (if (nil? keyword-dicts) true keyword-dicts)
   ignore-newlines
   return-mutable
   0
   reader-in))

(defn read-buffer
  "Reads the first bencoded value from the provided buffer, returns null if
  there is no data to read.

  If the keyword-dicts value is true, then the keys of dictionaries will be
  turned into keywords (the default is true).

  If the ignore-newlines value is true, then new line characters in between the
  bencoded values will be ignored (the default is false).

  If the return-mutable value is true, then the result uses mutable data
  structures (the default is false)."
  [buffer-in &keys {:keyword-dicts keyword-dicts
                    :ignore-newlines ignore-newlines
                    :return-mutable return-mutable}]
  (let [reader-in (reader buffer-in)]
    (read reader-in
          :keyword-dicts keyword-dicts
          :ignore-newlines ignore-newlines
          :return-mutable return-mutable)))

(defn read-stream
  "Reads the first bencoded value from the provided stream. If there is no data
  in the stream to be read, this function will block until data is available.

  If the keyword-dicts value is true, then the keys of dictionaries will be
  turned into keywords (the default is true).

  If the ignore-newlines value is true, then new line characters in between the
  bencoded values will be ignored (the default is false).

  If the return-mutable value is true, then the result uses mutable data
  structures (the default is false)."
  [stream &keys {:keyword-dicts keyword-dicts
                 :ignore-newlines ignore-newlines
                 :return-mutable return-mutable}]
  (let [reader-in (reader-stream stream)]
    (read reader-in
          :keyword-dicts keyword-dicts
          :ignore-newlines ignore-newlines
          :return-mutable return-mutable)))

(defn- write-integer
  "Writes the bencoded representation of the provided integer to the buffer."
  [buffer-out int-in]
  (buffer/push-byte buffer-out INT-FLAG)
  (buffer/push-string buffer-out (string int-in))
  (buffer/push-byte buffer-out END-FLAG))

(defn- write-string
  "Writes the bencoded represnetation of the provided string to the buffer."
  [buffer-out string-in]
  (buffer/push-string buffer-out (string (length string-in)))
  (buffer/push-byte buffer-out LENGTH-SEPARATOR)
  (buffer/push-string buffer-out string-in))

(defn- write-list
  "Writes the bencoded representation of the provide list to the buffer,
  the write-fn is used to encoded nested structures."
  [write-fn buffer-out list-in]
  (buffer/push-byte buffer-out LIST-FLAG)
  (let [sorted-in (sort-by string (apply array list-in))]
    (seq [index :range [0 (length sorted-in)]]
         (write-fn buffer-out (get sorted-in index))))
  (buffer/push-byte buffer-out END-FLAG))

(defn- write-map
  "Writes the bencoded representation of the provided map to the buffer, the
  write-fn is used to encode nested structures. Keywords are transformed into
  strings (i.e. \":key\" becomes \"key\")."
  [write-fn buffer-out map-in]
  (buffer/push-byte buffer-out DICTIONARY-FLAG)
  (let [sort-fn (fn [pair] (string (first pair)))
        sorted-map (sort-by sort-fn (pairs map-in))]
    (seq [index :range [0 (length sorted-map)]]
         (buffer (write-string buffer-out (first (get sorted-map index)))
                 (write-fn buffer-out (last (get sorted-map index))))))
  (buffer/push-byte buffer-out END-FLAG))

(defn write-buffer
  "Write the bencoded representation of the data structure to the provided
  buffer, keywords will be turned into strings (i.e. \":key\" becomes \"key\").

  If the strict-conversion value is true, the invariant
  (= str (decode (encode str))) always holds (the default is false). When false,
  this mostly means that keyword and symbol values will be converted to strings
  when encoded."
  [buffer-out data &keys {:strict-conversion strict-conversion}]
  (cond
    (int? data)
    (write-integer buffer-out data)

    (or (string? data) (buffer? data))
    (write-string buffer-out data)

    (and (or (keyword? data) (symbol? data)) (not strict-conversion))
    (write-string buffer-out data)

    (or (array? data) (tuple? data))
    (write-list write-buffer buffer-out data)

    (or (table? data) (struct? data))
    (write-map write-buffer buffer-out data)

    (write-error "Unknown type" data)))

(defn write
  "Returns a buffer with the bencoded representation of the data structure,
  keywords will be turned into strings (i.e. \":key\" becomes \"key\").

  If the strict-conversion value is true, the invariant
  (= str (decode (encode str))) always holds (the default is false). When false,
  this mostly means that keyword and symbol values will be converted to strings
  when encoded."
  [data &keys {:strict-conversion strict-conversion}]
  (let [buffer-out @""]
    (write-buffer buffer-out data :strict-conversion strict-conversion)))
