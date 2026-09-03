"use client";

type Props = {
  pending: boolean;
  hash?: `0x${string}`;
  confirming: boolean;
  success: boolean;
  errorMessage?: string;
};

export function TxStatus({ pending, hash, confirming, success, errorMessage }: Props) {
  if (!pending && !hash && !errorMessage) return null;

  return (
    <div className="tx-status">
      {pending && <p className="tx-pending">Waiting for wallet confirmation...</p>}
      {hash && confirming && <p className="tx-pending">Transaction submitted, waiting for receipt...</p>}
      {hash && success && <p className="tx-success">Confirmed.</p>}
      {errorMessage && <p className="tx-error">{errorMessage}</p>}
      {hash && (
        <p className="tx-hash">
          Tx: <code>{hash}</code>
        </p>
      )}
    </div>
  );
}
