# LifeDrive User Manual

**Audience:** people who run a LifeDrive node, and the people who use it.
**Covers:** installing LifeDrive on a node, upgrading it, how identity works, and what to do when a device or an identity is lost.
**Current release:** 0.7.35 (`npm view @inoku/lifedrive version` shows the latest).

LifeDrive is a private drive that runs on your own Leither node. Your files stay on
that node; phones, tablets and browsers connect to it directly. There is no
LifeDrive account on the Internet and no password: each device holds its own key,
and a device you already trust approves every new one.

---

## 1. Before you start

A LifeDrive node needs:

| Requirement | Notes |
|---|---|
| A Linux or macOS computer | Fresh setup installs Leither if missing, or reuses an existing node. Intel/AMD64 and Apple Silicon/ARM64 are supported. |
| Node.js 18 or later | Used only to run the installer with `npx`. |
| `bash`, `curl`, `tar`, and `sha256sum` or `shasum` | Present on most Linux and macOS systems. |
| Your normal user account | If Leither already exists, use its account. Setup uses `sudo` to register the Leither and LifeDrive identity system services; both run as your normal account. |
| A system service manager | systemd on Linux, launchd on macOS. They start newly installed Leither nodes at boot and recover them after crashes. |
| The LifeDrive app on your phone | iPhone or Android. The first user is created from a phone. |

LifeDrive never stops or restarts Leither. If more than one Leither node runs on
the machine, the installer lists them and asks you to choose one with
`--leither-root <directory>`.

---

## 2. Install LifeDrive on a node

### 2.1 Install LifeDrive

On macOS, use Terminal. Both Apple Silicon and Intel Macs use the same npm package and commands as Linux; no separate package name or Homebrew installation is needed. Node.js must already be installed; the package can install Leither for you.

On the node, as the account that runs Leither:

```bash
npx --yes @inoku/lifedrive@latest
```

The installer finds an existing running Leither node. If none is running, it
reuses Leither in the selected directory, current directory, or `PATH`, or
downloads and verifies the official runtime for your machine. A new node is
created in `~/.local/share/lifedrive/leither`, initialized with its own private
keys, and started as a system service with automatic boot startup. Setup waits for Leither's local version
endpoint, verifies the LifeDrive archive, installs LifeDrive and runs terminal
setup. Follow its prompts.

To choose another empty directory or start a stopped existing node:

```bash
npx --yes @inoku/lifedrive@latest --leither-root "/path/to/leither"
```

Existing Leither files are never replaced. If a directory contains files but no
Leither executable, setup stops instead of initializing over them. Use
`--no-install-leither` to require a running node. Upgrades and device-management
commands always require a running node. An older existing Leither version must
be upgraded separately to V0.24.11 or newer.

Fresh Leither downloads require access to the [official distribution](http://vzhan.cn/#start.html).
Port 4800 must be available for a new node. On Linux, inspect startup with
`systemctl status lifedrive-leither.service` and
`journalctl -u lifedrive-leither.service`. On macOS, use
`sudo launchctl print system/uk.inoku.leither` and read
`<Leither root>/leither-service.log`. The service starts at boot and continues
after you log out. Run setup as your normal user, not with `sudo npx`; it will
request sudo only for system service registration and management.

To add boot startup to an existing node without changing LifeDrive files:

```bash
npx --yes @inoku/lifedrive@latest --leither-service --leither-root "/path/to/leither"
```

A service already installed by this package is enabled without restarting it.
If Leither is running manually or under another manager, setup leaves it alone.
Keep that manager, or stop the node during a maintenance window and disable its
old boot registration before running the service-only command. Existing service
definitions with different settings are not overwritten. Regular LifeDrive
upgrades do not change or restart Leither's service.

If a LifeDrive is already installed on this node, the installer stops and says so.
Use the upgrade in section 3 instead.

### 2.2 Turn on users and mobile setup

Still on the node:

```bash
npx --yes @inoku/lifedrive@latest --upgrade --household
```

This keeps what step 2.1 installed and adds users and phones:

1. Creates LifeDrive's private configuration in `<Leither root>/.lifedrive-household/`.
2. Installs and starts the identity service using `sudo`: `lifedrive-identity` through systemd on Linux, or `uk.inoku.lifedrive-identity` through launchd on macOS. Both run under your Leither account. The Mac service starts at boot and continues after Terminal closes or you log out. Leither itself is not restarted and must be running separately. Stop any old foreground identity service before switching to the Mac daemon.
3. Prints a **setup invitation**: a block of text, followed by
   *"Keep the invitation above private. It expires in ten minutes."*

The setup invitation is what makes a phone the first user of this node. Treat it
like a key: do not post it, email it to others, or paste it anywhere public.

### 2.3 Create the first user from your phone

Within ten minutes of the invitation being printed:

1. Copy the whole invitation block from the terminal and send it to your phone, or copy it on a computer your phone shares a clipboard with.
2. Open LifeDrive on the phone. The **Set up your LifeDrive** screen opens by itself (or open **Settings → Set up users**).
3. Enter **Your name** and a name for this device.
4. Tap **Paste node identity** (or **Choose identity file** if you saved the invitation as a file).

The phone creates its own device key, claims the node, and opens your new, empty
personal drive. You are now the node's first user and its **administrator**, and
this phone is a **device manager**.

You can close the setup screen without pairing to look around the app. Tapping an
empty page, or **Settings → Set up users**, opens it again.

### 2.4 If setup is interrupted

| Situation | What to do |
|---|---|
| The invitation expired before you pasted it | On the node, stop the identity service (`sudo systemctl stop lifedrive-identity` on Linux, or `sudo launchctl bootout system/uk.inoku.lifedrive-identity` on macOS) and run the command from 2.2 again for a fresh invitation. |
| You pasted it, but the app lost its connection or was closed | Open the app on **the same phone** and paste **the same invitation** again. A claim that has started can finish after the ten minutes have passed. Do not delete the app or ask for a new invitation: that would abandon the phone's pending key. |
| Setup says the node already has users | The node has been claimed. Add further devices from **My devices** (section 4), not with a new setup invitation. |

### 2.5 Check that the node is healthy

On the node:

```bash
systemctl status lifedrive-identity          # Linux: should be "active (running)"
sudo launchctl print system/uk.inoku.lifedrive-identity  # macOS: should report state = running
curl -s http://127.0.0.1:4811/health         # should print the service name and node ID
```

---

## 3. Upgrade LifeDrive

Upgrading replaces the LifeDrive application and the identity service program.
**Users, device keys, files and backups are preserved.** Upgrading does not
restart Leither.

### 3.1 Upgrade the node

On the node, as the account that runs Leither:

```bash
npx --yes @inoku/lifedrive@latest --upgrade
```

To install a specific release instead of the latest, name it, for example
`npx --yes @inoku/lifedrive@0.7.35 --upgrade`. Release versions are never reused,
so a version number always means the same files.

The installer saves the previous application files to a backup directory, prints
where, and then:

```text
LifeDrive application and identity-service files updated. Household users and keys were preserved.
Restart only the LifeDrive identity service through its service manager to load the new binary.
```

Then restart the identity service so the new program runs:

```bash
sudo systemctl restart lifedrive-identity    # Linux
systemctl status lifedrive-identity          # confirm it is running again
```

On macOS:

```bash
sudo launchctl kickstart -k system/uk.inoku.lifedrive-identity
sudo launchctl print system/uk.inoku.lifedrive-identity
curl --fail http://127.0.0.1:4811/health
```

If startup fails, inspect `<Leither root>/.lifedrive-household/identity.log`.
Custom configurations installed with `--household-config` still use the manual
start command printed during installation.

While the service restarts, apps show a connection error for a few seconds and
retry by themselves. Uploads and backups that were in progress resume.

### 3.2 Upgrade the apps

Update LifeDrive on each phone from its app store or distribution channel as
usual. The browser client updates itself when the page is reloaded.

---

## 4. Identity: users, devices and invitations

### 4.1 What LifeDrive keeps

| Thing | What it is |
|---|---|
| **Node** | Your Leither server. Its identity is fixed; its network address may change without affecting you. |
| **User** | A person with their own private drive on the node. Created once, from a phone. Users cannot see each other's files. |
| **Administrator** | The first user. Can invite other people to create their own users. Being administrator gives no access to other users' files. |
| **Device** | One phone, tablet, computer or browser signed in as a user. Each device has **its own key**, created on that device and never copied anywhere. |
| **Device manager** | A device allowed to approve new devices and remove devices. Phones and tablets are managers by default; a browser is not, unless a manager promotes it. |

Nothing in LifeDrive is protected by a password, and there is no "identity file"
that can sign you in on its own. Every invitation below only *asks* to join; a
device you already use has to approve.

### 4.2 Add another of your own devices

On a device manager you already use:

1. Open **Settings → My devices → Pair another device**.
2. The app creates an invitation file (`lifedrive-user.identity.json`) and opens the share sheet. Send it to the new device with AirDrop, a messaging app, or save it to Files.
3. On the new device, open LifeDrive, choose **Settings → Set up users**, enter a device name, and import the file (**Choose identity file**).
4. The new device shows a **match code**. On the manager, open **My devices** (pull down to refresh if needed), check that the code shown there is the same, and tap **Approve this device**.

The new device opens the same drive. The invitation expires shortly after it is
created, and a copy of it cannot be used by anyone else once your new device has
used it.

### 4.3 Sign in a browser

1. On your phone, open **Settings → My devices → Pair a browser**. It shows the browser address for your node, with **Copy browser URL** and **Share browser URL**.
2. Open that address in a browser on a computer connected to the same network. The page shows a QR code.
3. On the phone, tap **Scan browser QR code**, scan the code, and approve.

The browser gets its own session. It stays signed in until it goes seven days
without being used, or until you remove it. A browser starts without device-manager
rights; a manager can grant them with **Allow device management** in My devices.

### 4.4 Invite another person

Only the administrator can do this.

1. **Settings → My devices → Invite another user** creates an invitation and opens the share sheet. Send it to the person.
2. They install LifeDrive on their phone, open **Settings → Set up users**, enter their own name, and import the invitation.

They get their own empty drive. Nothing of yours is shared with them unless you
share a file or folder with a link.

### 4.5 Manage devices

In **Settings → My devices** every device of your user is listed with its name,
type, status and last activity. A device manager can:

- **Rename** a device.
- **Remove access**: the device is signed out on its next request and can no longer read or change your drive. Files it had already downloaded stay on it.
- **Allow device management**: give a browser manager rights.
- **Forget**: delete the record of a device that has already lost access. This only tidies the list; it does not change anyone's access.

**Removal needs a replacement already in place.** The node refuses to remove a
device unless at least one *other* active phone (iPhone or Android) and one other
active device manager remain, and says *"pair a replacement mobile and device
manager first"*. This keeps you from locking yourself out, and it decides the
order of steps in section 5.

### 4.6 Forget this identity on a device

**Settings → Forget this identity** deletes this device's key from the device. The
device is no longer signed in. Your drive and your other devices are unaffected.
To use the device again, pair it again as in 4.2 with an invitation from another
device you still use.

---

## 5. Recovering a lost identity

Your files live on the node, not on your phone. Losing a device does not lose
your drive. What you can lose is **the ability to sign in** — and that depends
on whether you still have another working device.

### 5.1 You lost a device, and you still have another phone that is a device manager

This is the normal case, and you can fix it yourself right away.

1. On the phone you still have, open **Settings → My devices**.
2. Find the lost device and tap **Remove access**. From its next request, the lost device can no longer reach your drive.
3. When you have a replacement, pair it with **Pair another device** (section 4.2).

Do this even if you expect to find the device again: pairing it again later takes
a minute.

If the lost device was your **only phone** and what you still have is a browser
or a computer, **Remove access** is refused until another phone is paired. Follow
5.2.

### 5.2 You lost your only phone, but a browser is still signed in

A browser can only approve new devices if it was given **Allow device management**
beforehand. If it was, the order matters, because the lost phone cannot be removed
while it is your only phone:

1. In the browser, open **My devices → Pair another device** and save the invitation.
2. Import it on the new phone (**Settings → Set up users → Choose identity file**) and approve the match code in the browser.
3. Now remove the lost phone: **My devices → Remove access**.

Until step 3 the lost phone still has access, so do this as soon as you can.

If the browser was not a device manager, it can still read and download your
files, but it cannot approve a new phone. Continue with 5.3.

### 5.3 You lost every device

There is no recovery code, recovery file or password to fall back on. The app
used to offer a recovery file; that option has been removed, because a file that
can restore an account on its own is as dangerous to lose as the account itself.

What remains true:

- **Your files are safe on the node.** Nothing is deleted when devices are lost.
- **Other users are unaffected.** Their drives and devices keep working.
- **Recovery needs the node operator.** Contact whoever runs the node.

For node operators: LifeDrive does not yet include a repair command that binds a
new device to an existing user. The setup invitation (`--household`) only works
on a node that has no users, so it cannot be used for this. Until the repair
command exists, recovering a user who has lost every device needs help from the
LifeDrive maintainers. Do not delete or edit `.lifedrive-household/` to try to
work around it: it holds every user's authority and the authorization journal.

### 5.4 Prevent lockout

- **Pair at least two phones as device managers**, for example an iPhone and an Android phone, or your phone and a family member's old phone kept at home. (Tablets count as phones here only if they run the iPhone or Android app.) This alone turns every "lost device" into the easy case in 5.1.
- If you mainly use a computer, give its browser **Allow device management** so it can stand in for a lost phone.
- Remove access for a lost device as soon as you notice, from any device you still have.

### 5.5 For node operators: protect the node's identity data

The directory `<Leither root>/.lifedrive-household/` holds each user's storage
authority, the device authorization journal, the node's transport key and staged
uploads that have not been committed yet.

- **Back it up** together with the Leither node's data. Without it, the drives on the node cannot be used by their owners even though the files still exist.
- **Keep it private.** Anyone with a copy holds every user's storage authority. Never put it in a shared folder, a public repository or an application bundle.
- **Do not restore an old copy over a running service** to undo a device removal: authorization only moves forward, and an old copy can re-open access that was deliberately removed.

---

## 6. Quick reference

| Task | Where |
|---|---|
| Install on a node | `npx --yes @inoku/lifedrive@latest`, then `npx --yes @inoku/lifedrive@latest --upgrade --household` |
| Upgrade a node | `npx --yes @inoku/lifedrive@latest --upgrade`, then `sudo systemctl restart lifedrive-identity` |
| Check the node | `systemctl status lifedrive-identity` and `curl -s http://127.0.0.1:4811/health` |
| Create the first user | Phone: **Settings → Set up users → Paste node identity** |
| Add your own device | Existing device: **My devices → Pair another device**; new device: **Set up users → Choose identity file**; approve the match code |
| Sign in a browser | Phone: **My devices → Pair a browser**; open the address it shows; **Scan browser QR code** |
| Invite another person | Administrator: **My devices → Invite another user** |
| Lost a device | Another phone: **My devices → Remove access**, then pair a replacement. Lost your only phone: pair the replacement first (section 5.2) |
| Lost every device | Contact the node operator (section 5.3) |
