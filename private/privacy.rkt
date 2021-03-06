#lang racket/base
;;
;; simple-oauth2 - oauth/private/privacy.
;;   Simple OAuth2 client and server implementation
;;
;; Copyright (c) 2019 Simon Johnston (johnstonskj@gmail.com).

;; Racket Style Guide: http://docs.racket-lang.org/style/index.html

(require racket/contract)

(provide encrypt-secret
         decrypt-secret
         encode-client)

;; ---------- Requirements

(require crypto
         crypto/libcrypto
         net/base64
         net/uri-codec
         oauth2
         oauth2/storage/config)

;; ---------- Implementation (encryption)

(crypto-factories (list libcrypto-factory))

(define crypto-cipher (get-preference 'cipher-impl))
(define crypto-key (get-preference 'cipher-key))
(define crypto-iv (get-preference 'cipher-iv))
(define crypto-aad (get-current-user-name/bytes))

; using an Authenticated Encryption (AEAD) cipher, such as AES-GCM, along with
; Additionally Authenticated Data (AAD) adds an additional feature in that
; if the file is copied and loaded by a user other than the one that saved it
; the decryption process will fail.
(define (encrypt-secret s)
  ; encrypt will store bytes
  (encrypt crypto-cipher crypto-key crypto-iv s #:aad crypto-aad))

(define (decrypt-secret cs)
  ; need to convert back to text
  (bytes->string/latin-1 (decrypt crypto-cipher crypto-key crypto-iv cs #:aad crypto-aad)))

(define (encode-client client)
  ;; See <https://tools.ietf.org/html/rfc2617> section 2
  ;; The Authorization header must be set to Basic followed by a space,
  ;; then the Base64 encoded string of your application's client id and
  ;; secret concatenated with a colon. For example, the Base64 encoded
  ;; string, `Y2xpZW50X2lkOmNsaWVudCBzZWNyZXQ=`, is decoded as
  ;; `[client_id]:[client_secret]`.
  (base64-encode
   (string->bytes/latin-1
    (format "~a:~a"
            (form-urlencoded-encode (client-id client))
            (form-urlencoded-encode (client-secret client))))
   ""))

;; ---------- Internal tests


(module+ test
  (require rackunit)

  ;; encrypt -> decrypt
  (define plain-text "my-secret-string")
  (define cipher-text (encrypt-secret plain-text))
  (check-equal? (decrypt-secret cipher-text) plain-text)
  (check-equal? (decrypt-secret (encrypt-secret plain-text)) plain-text)
  (check-equal? (encrypt-secret (decrypt-secret cipher-text)) cipher-text)
  
  ;; encode-client
  (check-equal?
   (encode-client (make-client "Face Service" "johnstonskj" "my-secret-string"
                               "https://example.com/auth" "https://example.com/token"))
   #"am9obnN0b25za2o6bXktc2VjcmV0LXN0cmluZw==")
  )