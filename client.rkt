#lang racket/base
;;
;; simple-oauth2 - oauth2/client.
;;   Simple OAuth2 client and server implementation
;;
;; Copyright (c) 2019 Simon Johnston (johnstonskj@gmail.com).

; This implementation references the following specifications:
;
; The OAuth 2.0 Authorization Framework <https://tools.ietf.org/html/rfc6749>
;
; Proof Key for Code Exchange (PKCE) by OAuth Public Clients <https://tools.ietf.org/html/rfc7636>
;
; OAuth 2.0 Token Revocation <https://tools.ietf.org/html/rfc7009>
;
; OAuth 2.0 Token Introspection <https://tools.ietf.org/html/rfc7662>

(provide 
  create-random-state
  create-pkce-challenge
  request-authorization-code
  fetch-token/from-code
  fetch-token/implicit
  fetch-token/with-password
  fetch-token/with-client
  make-request-auth-header)

;; ---------- Requirements

(require racket/bool
         racket/list
         racket/match
         racket/port
         racket/random
         racket/string
         racket/system
         file/sha1
         json
         net/base64
         net/http-client
         net/uri-codec
         net/url
         net/url-string
         oauth2
         oauth2/private/redirect-server
         oauth2/private/logging
         oauth2/private/privacy)

;; ---------- Internal types

(define APPLICATION/JSON "application/json")

(define APPLICATION/FORM-MIME-TYPE "application/x-www-form-urlencoded")

(define-struct pkce
  (verifier
   code
   method))

;; ---------- Implementation

(define (create-random-state [bytes 16])
  (unless (and (exact-nonnegative-integer? bytes) (> bytes 8) (< bytes 128))
    (error 'create-random-state "not a valid value for number of bytes: " bytes))
  (bytes->hex-string (crypto-random-bytes bytes)))

(define (create-pkce-challenge [a-verifier #f])
  ;; See <https://tools.ietf.org/html/rfc7636> section 4.1
  ;; S256
  ;;   code_challenge = BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))
  ;;   code-verifier = 43*128unreserved
  ;;   unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"
  ;;   ALPHA = %x41-5A / %x61-7A
  ;;   DIGIT = %x30-39
  (define verifier 
    (cond
      [(false? a-verifier)
        (string-replace 
          (string-replace 
            (string-replace (base64-encode (crypto-random-bytes 48) #"") "+" "-" #:all #t)
            "/" "_" #:all #t)
          "=" "" #:all #t)]
      [(string? a-verifier) a-verifier]
      [else (format "~a" a-verifier)]))
  (define challenge (sha256-bytes verifier))
  ; only support 'S256' option, no need for 'plain'
  (make-pkce verifier challenge "S256"))

(define (request-authorization-code client scopes #:state [state #f] #:challenge [challenge #f] #:audience [audience #f])
  ;; See <https://tools.ietf.org/html/rfc6749> section 4.1
  ;; See <https://tools.ietf.org/html/rfc7636> section 4.3
  (log-oauth2-info "request-authorization-code from ~a" (client-service-name client))
  (define use-state (if (false? state) (create-random-state) state))
  (define query (append (list (cons 'response_type "code")
                              (cons 'client_id (client-id client))
                              (cons 'redirect_uri (get-redirect-uri))
                              (cons 'scope (string-join scopes " "))
                              (cons 'state use-state))
                        (if (false? audience) 
                            (list) 
                            (list (cons 'audience audience)))
                        (if (false? challenge) 
                            (list) 
                            (list (cons 'code_challenge (pkce-code challenge))
                                  (cons 'code_challenge_method (pkce-method challenge))))))
  (define query-string (alist->form-urlencoded query))
  (define full-url 
    (url->string 
      (combine-url/relative 
        (client-authorization-uri client)
        (string-append "?" query-string))))
  (parameterize ([current-error-port (open-output-string "stderr")])
    (define cmd (format (match (system-type 'os)
                          ['windows "cmd /c start \"~a\""]
                          ['macosx "open \"~a\""]
                          ['unix "xdg-open \"~a\""])
                         full-url))
  (log-oauth2-debug "starting browser: ~a" cmd)
    (define success? (system cmd))
    (cond 
      [success?
        ; return the response channel
        (record-auth-request use-state)]
      [else
        (define error-string (get-output-string (current-error-port)))
        (log-oauth2-error "system call failed. error: ~a" error-string)
        (error "system call failed. error: " error-string)])))

(define (fetch-token/from-code client authorization-code #:challenge [challenge #f])
  ;; See <https://tools.ietf.org/html/rfc6749> section 4.1.3
  ;; See <https://tools.ietf.org/html/rfc7636> section 4.5
  (log-oauth2-info "fetch-token/from-code, service ~a, code ~a" (client-service-name client) authorization-code)
  (fetch-token-common
    client
    (append (list (cons 'grant-type "authorization_code")
                  (cons 'code authorization-code)
                  (cons 'redirect_uri redirect-server-uri)
                  (cons 'client-id (client-id client)))
            (if (false? challenge) 
                (list) 
                (list (cons 'code_verifier (pkce-verifier challenge)))))))

(define (fetch-token/implicit client scopes #:state [state #f] #:audience [audience #f])
  ;; See <https://tools.ietf.org/html/rfc6749> section 4.2.1
  #f)

(define (fetch-token/with-password client username password)
  ;; See <https://tools.ietf.org/html/rfc6749> section 4.3.2
  (log-oauth2-info "fetch-token/with-password, service ~a, username ~a" (client-service-name client) username)
  (fetch-token-common
    client
    (append (list (cons 'grant-type "password")
                  (cons 'username username)
                  (cons 'password password)
                  (cons 'client-id (client-id client))))))

(define (fetch-token/with-client client)
  ;; See <https://tools.ietf.org/html/rfc6749> section 4.4.2
  (log-oauth2-info "fetch-token/native, service ~a" (client-service-name client))
  (fetch-token-common
    client
    (append (list (cons 'grant-type "password")
                  (cons 'client-id (client-id client))
                  (cons 'client-secret (client-secret client))))))

(define (refresh-token client token)
  ;; See <https://tools.ietf.org/html/rfc6749> section 6
  (log-oauth2-info "refresh-token, service ~a" (client-service-name client))
  (fetch-token-common
    client
    (append (list (cons 'grant-type "refresh_token")
                  (cons 'refresh_token (token-refresh-token token))
                  (cons 'client-id (client-id client))
                  (cons 'client-secret (client-secret client))))))

(define (revoke-token client token revoke-type)
  ;; See <https://tools.ietf.org/html/rfc7009> section 2.1
  (log-oauth2-info "revoke-token, service ~a" (client-service-name client))
  (fetch-token-common
    client
    (append (list (cons 'token_type revoke-type)
                  (cons 'token 
                    (cond
                      [(equal? revoke-type 'access-token)
                       (token-access-token token)]
                      [(equal? revoke-type 'refresh-token)
                       (token-refresh-token token)]
                      [else (error "unknown token type: " revoke-type)]))))))

(define (introspect-token client token token-type])
  ;; See <https://tools.ietf.org/html/rfc7662> section 2.1
  ;; Note:
  ;; The Authorization header must be set to Bearer followed by a space, 
  ;; and then a valid access token used for making the Introspect request.
  (log-oauth2-info "introspect-token, service ~a" (client-service-name client))
  (fetch-token-common
    client
    (append (list (cons 'token_type_hint token-type)
                  (cons 'token 
                    (cond
                      [(equal? token-type 'access-token)
                       (token-access-token token)]
                      [(equal? token-type 'refresh-token)
                       (token-refresh-token token)]
                      [else (error "unknown token type: " token-type)]))))))

(define (make-request-auth-header token)
  (string->bytes/utf-8 (format "Authorization: ~a" (token-type token) (token-access-token token))))

;; ---------- Internal Implementation

(define (fetch-token-common client data-list)
  (define header (format "Authorization: Basic ~a" (encode-client client)))
  (define response 
    (do-post/form-encoded-list/json 
      (client-token-uri client)
      (list header)
      data-list))
  (cond
    [(= (first response) 200)
     (token-from-response (last response))]
    [else
      ; TODO: check for JSON "error"
      (response)]))

(define (do-post/form-encoded-list/json uri headers data-list)
  (define response 
    (do-post
      uri
      headers
      (alist->form-urlencoded data-list)
      "application/x-www-form-urlencoded"))
  (list-update response 3 bytes->jsexpr))

(define (do-post/form-encoded-list uri headers data-list)
  (do-post
    uri
    headers
    (alist->form-urlencoded data-list)
    "application/x-www-form-urlencoded"))

(define (do-post uri headers data data-type)
  (define-values 
    (status headers in-port)
    (http-sendrecv
      (url-host uri)
      uri
      #:port (url-port uri)
      #:ssl? (equal? (url-scheme uri) "https")
      #:method "POST"
      #:headers (cons (format "Content-Type: ~a" data-type) headers)
      #:data data))
  (parse-response status headers in-port))

(define (string-split-first str sep)
  (define index 
    (for/or ([char (string->list str)] [i (range (string-length str))])
      (if (equal? char sep) i #f)))
  (if (false? index)
      (values str "")
      (values (substring str 0 index) (string-trim (substring str index)))))

(define (parse-response status headers in-port)
  (define-values (code msg) (string-split-first (bytes->string/utf-8 status) #\space))
  (list 
    (string->number code)
    msg
    (for/list ([header headers])
      (define-values (k v) (string-split-first (bytes->string/utf-8 header) #\:))
      (cons k v))
    (port->bytes in-port)))

(define (token-from-response json)
  (make-token
    (hash-ref json 'access_token)
    (hash-ref json 'token_type)
    (hash-ref json 'refresh_token #f)
    (hash-ref json 'audience #f)
    (string-split (hash-ref json 'scope "") ",")
    (seconds->date
      (+ (current-seconds) (string->number (hash-ref json 'expires_in "0"))))))