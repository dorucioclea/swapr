;; (use-trait can-transfer-tokens
;;     'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token.can-transfer-tokens)
;; (use-trait y-token
;;     'SP1QR3RAGH3GEME9WV7XB0TZCX6D5MNDQP97D35EH.my-token.can-transfer-tokens)

(define-constant contract-owner 'SZ2J6ZY48GV1EZ5V2V5RB9MP66SW86PYKKQ9H6DPR)
(define-constant no-liquidity-err (err u1))
(define-constant transfer-failed-err (err u2))
(define-constant not-owner-err (err u2))

;; (define-constant x-token 'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token)

;; overall balance of x-token and y-token held by the contract
(define-data-var x-balance uint u0)
(define-data-var y-balance uint u0)

;; fees collected so far, that have not been withdrawn (saves gas while doing exchanges)
(define-data-var fee-x-balance uint u0)
(define-data-var fee-y-balance uint u0)

;; balances help by all the clients holding positions, this is equal to the sum of all the balances held in positions by each client
(define-data-var total-balances uint u0)
(define-map positions
  ((owner principal))
  ((balance uint))
)

;; TOOD(psq): refactor by using optional var
;; only to store wether the contract should capture a 5 bp fee, and where to send the fee
(define-map fee-to
  ((key uint)) ;; only valid value is u0
  ((address principal))
)
(define-data-var fee-to-add (optional principal) none)

(define-private (position-of (owner principal))
  (default-to u0
    (get balance
      (map-get? positions ((owner owner)))
    )
  )
)

(define-read-only (get-position-of (owner principal))
  (ok (position-of owner))
)

(define-read-only (get-positions)
  (ok (var-get total-balances))
)

(define-read-only (get-balances-of (owner principal))
  (let ((x (var-get x-balance)) (y (var-get y-balance)) (balance (var-get total-balances)) (share (position-of owner)))
    (if (> balance u0)
      (ok (list (/ (* x share) balance) (/ (* y share) balance)))  ;; less precision loss doing * first
      no-liquidity-err  ;; no liquidity
    )
  )
)

;; Decrease position of a specified spender.
(define-private (decrease-position (owner principal) (amount uint))
  (let ((balance (position-of owner)))
    (if (or (> amount balance) (<= amount u0))
      true
      (begin
        (map-set positions
          ((owner owner))
          ((balance (- balance amount))))
        true)
    )
  )
)

;; Internal - Increase position of a specified spender.
(define-private (increase-position (owner principal) (amount uint))
  (let ((balance (position-of owner)))
    (if (<= amount u0)
      false
      (begin
        (print (tuple (owner owner)))
        (print (map-set positions
          ((owner owner))
          ((balance (+ balance amount)))))
        true)
    )
  )
)

;; get overall balances for the pair
(define-read-only (get-balances)
  (ok (list (var-get x-balance) (var-get y-balance)))
)

;; x: 'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token
;; y: 'SP1QR3RAGH3GEME9WV7XB0TZCX6D5MNDQP97D35EH.my-token

;; how much of each token to buy, unless this is the first addition
;; this will respect current ratio
;; TODO(psq): use 0 for x or y to get perfect ratio based on current exchange rate
(define-public (add-to-position (x uint) (y uint))
  (let ((contract-address (as-contract tx-sender)))
    (if
      (and
        (is-ok (print (contract-call? 'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token transfer contract-address x)))
        (is-ok (print (contract-call? 'SP1QR3RAGH3GEME9WV7XB0TZCX6D5MNDQP97D35EH.my-token transfer contract-address y)))
      )
      (begin
        (if (is-eq (var-get total-balances) u0)
          (begin
            (increase-position tx-sender x)
            (var-set total-balances x)
          )
          (let ((new-shares (* (/ x (var-get x-balance)) (var-get total-balances))))
            (increase-position tx-sender new-shares)
            (var-set total-balances (+ new-shares (var-get total-balances)))
          )
        )
        (var-set x-balance (+ x (var-get x-balance)))
        (var-set y-balance (+ y (var-get y-balance)))
        (ok true)
      )
      (begin
        transfer-failed-err
      )
    )
  )
)

;; to close, use 100
(define-public (reduce-position (percent uint))
  (let ((position (position-of tx-sender)) (balances (var-get total-balances)) (contract-address (as-contract tx-sender)) (sender tx-sender))
    (let ((withdrawal (/ (* position percent) u100)))
      (let ((remaing-position (- position withdrawal)) (withdrawal-x (/ (* withdrawal (var-get x-balance)) balances)) (withdrawal-y (/ (* withdrawal (var-get y-balance)) balances)))
        (if
          (and
            (<= percent u100)
            (is-ok (print (as-contract (contract-call? 'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token transfer sender withdrawal-x))))
            (is-ok (print (as-contract (contract-call? 'SP1QR3RAGH3GEME9WV7XB0TZCX6D5MNDQP97D35EH.my-token transfer sender withdrawal-y))))
          )
          (begin
            (decrease-position tx-sender withdrawal)
            (var-set total-balances (- balances withdrawal))
            (var-set x-balance (- (var-get x-balance) withdrawal-x))
            (var-set y-balance (- (var-get y-balance) withdrawal-y))
            (ok (list withdrawal-x withdrawal-y))
          )
          (begin
            (err transfer-failed-err)
          )
        )
      )
    )
  )
)

;; exchange known x for whatever y based on liquidity, returns y
(define-public (swap-exact-x-for-y (dx uint))
  ;; calculate y
  ;; calculate fee on x
  ;; transfer
  ;; update balances
  (let
    (
      (balances (var-get total-balances))
      (contract-address (as-contract tx-sender))
      (sender tx-sender)
      (dy (/ (* u997 (var-get x-balance) dx) (+ (* u100 (var-get x-balance)) (* u997 dx))))
      (fee (/ (* u5 dx) u10000))
    )
    (print balances)
    (print dx)
    (print dy)
    (if (and
      (is-ok (print (contract-call? 'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token transfer contract-address dx)))
      (is-ok (print (as-contract (contract-call? 'SP1QR3RAGH3GEME9WV7XB0TZCX6D5MNDQP97D35EH.my-token transfer sender dy))))
      )
      (begin
        (var-set x-balance (+ dx (var-get x-balance)))
        (var-set y-balance (+ dy (var-get y-balance)))
        (var-set fee-x-balance (+ fee (var-get fee-x-balance)))
        (ok (list dx dy))
      )
      transfer-failed-err
    )
  )
)

;; exchange whatever x for known y based on liquidity, returns x
(define-public (swap-x-for-exact-y (y uint))
  ;; calculate x
  ;; calculate fee on x
  ;; transfer
  ;; update balances

  (ok u0)
)

;; exchange known y for whatever x based on liquidity, returns x
(define-public (swap-exact-y-for-x (y uint))
  (ok u0)
)

;; exchange whatever y for known x based on liquidity, returns y
(define-public (swap-y-for-exact-x (x uint))
  (ok u0)
)

;; activate the contract fee for swaps by setting the collection address, restricted to contract owner
(define-public (set-fee-to-address (address principal))
  (begin
    (if (is-eq tx-sender contract-owner)
      (begin
        (map-set fee-to ((key u0)) ((address address)))
        (ok true)
      )
      not-owner-err
    )
  )
)

;; clear the contract fee for swaps by resetting the collection address
(define-public (reset-fee-to-address)
  (begin
    (if (is-eq tx-sender contract-owner)
      (begin
        (map-delete fee-to ((key u0)))
        (ok true)
      )
      not-owner-err
    )
  )
)

;; get the current address used to collect a fee
(define-public (get-fee-to-address)
  (begin
    (ok (get address (map-get? fee-to ((key u0)))))
  )
)

(define-public (collect-fees)
  (let ((fee-to-address (get address (map-get? fee-to ((key u0))))) (x (var-get fee-x-balance)) (y (var-get fee-y-balance)))
    (if
      (and
        (is-some fee-to-address)
        (is-ok (print (as-contract (contract-call? 'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token transfer (unwrap! fee-to-address transfer-failed-err) x))))
        (is-ok (print (as-contract (contract-call? 'SP1QR3RAGH3GEME9WV7XB0TZCX6D5MNDQP97D35EH.my-token transfer (unwrap! fee-to-address transfer-failed-err) y))))
      )
      (begin
        (var-set fee-x-balance u0)
        (var-set fee-y-balance u0)
        (ok (list x y))
      )
      transfer-failed-err
    )
  )
)

;; init the tokens, restricted to contract owner, callable only once
;; (define-public (init (x <can-transfer-tokens>) (y <can-transfer-tokens>))
;;   (ok u0)
;; )

;; (init 'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token 'SP1QR3RAGH3GEME9WV7XB0TZCX6D5MNDQP97D35EH.my-token)

;; (define-public (init (x <can-transfer-tokens>))
;;   (ok u0)
;; )

;; ;; (init 'SP2NC4YKZWM2YMCJV851VF278H9J50ZSNM33P3JM1.my-token)
;; (init 'SP1QR3RAGH3GEME9WV7XB0TZCX6D5MNDQP97D35EH.my-token)
