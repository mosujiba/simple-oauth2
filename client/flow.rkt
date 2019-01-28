#lang racket/base
;;
;; simple-oauth2 - oauth2/client/flow.
;;   Simple OAuth2 client and server implementation
;;
;; Copyright (c) 2019 Simon Johnston (johnstonskj@gmail.com).

(provide
  initiate-code-flow
  initiate-implicit-flow
  initiate-application-flow
  initiate-password-flow)

;; ---------- Requirements

(require racket/bool
         oauth2
         oauth2/client
         oauth2/storage/clients
         oauth2/storage/tokens
         oauth2/private/logging)

;; ---------- Implementation

(define (initiate-code-flow client scopes #:user-name [user-name #f] #:state [state #f] #:challenge [challenge #f] #:audience [audience #f])
  (log-oauth2-info "initiate-code-flow from ~a" (client-service-name client))

  (define response-channel
    (request-authorization-code
      client scopes
      #:state state #:challenge challenge #:audience audience))

  (define authorization-code
    (channel-get response-channel))
  (log-oauth2-debug "received auth-code ~a" authorization-code)

  (define token-response
    (fetch-token/from-code
      client authorization-code
      #:challenge challenge))
  (log-oauth2-debug "fetch-token/from-code returned ~a" token-response)

  (set-token!
    (if (false? user-name)
        (create-default-user)
        user-name)
    (client-service-name client)
    (token-access-token token-response))
  (save-tokens)

  token-response)

(define (initiate-implicit-flow) #f)

(define (initiate-application-flow) #f)

(define (initiate-password-flow) #f)