## 2.2.23.2 Lease Break Notification

The SMB2 Lease Break Notification packet is sent by the server when the underlying object store indicates that a lease is being broken, representing a change in the lease state. This notification is not valid for the SMB 2.0.2 dialect. This message is composed of an SMB2 header, as specified in section [2.2.1](5cd64522-60b3-4f3e-a157-fe66f1228052), followed by this notification structure:

<table><tbody><tr><th><p><br>0</p></th><th><p><br>1</p></th><th><p><br>2</p></th><th><p><br>3</p></th><th><p><br>4</p></th><th><p><br>5</p></th><th><p><br>6</p></th><th><p><br>7</p></th><th><p><br>8</p></th><th><p><br>9</p></th><th><p>1<br>0</p></th><th><p><br>1</p></th><th><p><br>2</p></th><th><p><br>3</p></th><th><p><br>4</p></th><th><p><br>5</p></th><th><p><br>6</p></th><th><p><br>7</p></th><th><p><br>8</p></th><th><p><br>9</p></th><th><p>2<br>0</p></th><th><p><br>1</p></th><th><p><br>2</p></th><th><p><br>3</p></th><th><p><br>4</p></th><th><p><br>5</p></th><th><p><br>6</p></th><th><p><br>7</p></th><th><p><br>8</p></th><th><p><br>9</p></th><th><p>3<br>0</p></th><th><p><br>1</p></th></tr><tr><td colspan="16"><p>StructureSize</p></td><td colspan="16"><p>NewEpoch</p></td></tr><tr><td colspan="32"><p>Flags</p></td></tr><tr><td colspan="32"><p>LeaseKey</p></td></tr><tr><td colspan="32"><p>...</p></td></tr><tr><td colspan="32"><p>...</p></td></tr><tr><td colspan="32"><p>...</p></td></tr><tr><td colspan="32"><p>CurrentLeaseState</p></td></tr><tr><td colspan="32"><p>NewLeaseState</p></td></tr><tr><td colspan="32"><p>BreakReason</p></td></tr><tr><td colspan="32"><p>AccessMaskHint</p></td></tr><tr><td colspan="32"><p>ShareMaskHint</p></td></tr></tbody></table>

**StructureSize (2 bytes):** The server MUST set this to 44, indicating the size of the response structure, not including the header.

**NewEpoch (2 bytes):** A 16-bit unsigned integer indicating a lease state change by the server. This field is only valid for a server implementing the SMB 3.x dialect family.

For the SMB 2.1 dialect, this field MUST NOT be used and MUST be reserved. The server MUST set this to 0, and the client MUST ignore it on receipt.

**Flags (4 bytes):** The field MUST be constructed by using zero or more of the following values.

| Value | Meaning |
| --- | --- |
| SMB2\_NOTIFY\_BREAK\_LEASE\_FLAG\_ACK\_REQUIRED  0x01 | A [Lease Break Acknowledgment](048aae06-3421-418b-85b3-0f7605749596) is required. |

**LeaseKey (16 bytes):** The client-generated key that identifies the owner of the lease.

**CurrentLeaseState (4 bytes):** The current lease state of the open. This field MUST be constructed using the following values.

| Value | Meaning |
| --- | --- |
| SMB2\_LEASE\_READ\_CACHING  0x01 | A read caching lease is granted. |
| SMB2\_LEASE\_HANDLE\_CACHING  0x02 | A handle caching lease is granted. |
| SMB2\_LEASE\_WRITE\_CACHING  0x04 | A write caching lease is granted. |

**NewLeaseState (4 bytes):** The new lease state for the open. This field MUST be constructed using the SMB2\_LEASE\_NONE or above values.

**BreakReason (4 bytes):** This field MUST NOT be used and MUST be reserved. The server MUST set this to 0, and the client MUST ignore it on receipt.

**AccessMaskHint (4 bytes):** This field MUST NOT be used and MUST be reserved. The server MUST set this to 0, and the client MUST ignore it on receipt.

**ShareMaskHint (4 bytes):** This field MUST NOT be used and MUST be reserved. The server MUST set this to 0, and the client MUST ignore it on receipt.
