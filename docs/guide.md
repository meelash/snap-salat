---
title: Using the app
description: How volunteers update their masjid's prayer times with Snap Salat.
---

# Using the app

Snap Salat is for the people who keep a masjid's prayer times up to date. When
the times on the board change, you photograph the board, check what the app
read, and send it. The masjid's website updates by itself.

The app works on **Android** and **iPhone**.

## Getting set up (once)

1. **Choose your masjid.** Tap *Choose your masjid*. Find it in the
   **Directory** by country, region and city, or tap **Enter address** and type
   the address your masjid gave you (it looks like
   `https://something.org/snap-salat`).
2. **Register.** Tap **Register**, enter your name, and choose a username and
   password. You can add a phone number or a note so the masjid knows who you
   are.
3. **Wait for approval.** Someone at the masjid approves new volunteers. Until
   then, the home screen shows *Waiting for the masjid to approve you*. Tap
   **Check again** to see if you've been approved.

Already have an account? Just sign in.

## Updating the times

1. **Take the photo.** Tap **Take photo** and photograph the prayer-time board.
   You can also choose one you took earlier.
2. **Check the times.** The app pins a number on each clock or time it found,
   and shows a tile with that number for each prayer:
   - an amber tile marked **Please check** means the app wasn't sure, so look
     closely at that one;
   - a red tile means it couldn't read that clock, so tap it and enter the time;
   - tap any tile to change its time, and hold it to clear a time that isn't on
     the board.
3. **Send.** Tap **Send to *your masjid***, confirm, and you're done.

The time the photo was taken comes from the camera and **can't be changed**.
That's how the masjid knows the times are current.

<figure>
  <img src="{{ '/assets/img/app-review.png' | relative_url }}" alt="The review screen: the board with numbered pins, and a tile per prayer" width="390" height="1235" style="max-width: 340px">
  <figcaption>Checking the times. Maghrib and Isha are marked “Please check”: Maghrib’s hands overlap exactly, and glare covers Isha’s minute hand.</figcaption>
</figure>

### Tips for a good photo

- Stand **straight in front** of the board, close enough that it fills most of
  the photo.
- **Avoid glare.** Step to one side if a window or light reflects off the
  glass, and turn off the flash.
- Keep the whole board in the photo, including any clock that shows the current
  time.
- Use a fresh photo. Masajid can reject old ones.

## Displays it can read

| Display | Status |
|---|---|
| **Analog clock boards**: one clock per prayer, often with a bigger clock for the current time | ✅ Supported. Works out which clock is which from the layout and the time of day. |
| **Printed or written boards** with times in a table | ✅ Supported, using on-device text recognition (Latin script; prayer names in English or Arabic). |
| **Screens and TVs** showing a timetable | ✅ Same as printed boards. |
| **LCD / LED digit displays** | ⚠️ Partly. Common digit look-alikes are corrected, but some fonts aren't read yet. |
| **Arabic-Indic digits** (٠١٢٣…) | ❌ Not yet. |

**If the app misreads your board,** fix the times, then tap **Share this
photo** at the bottom of the screen. It opens a short form already filled in
with what the app read and your corrections; you attach the photo. Real
examples are how support for new boards gets built.

## Privacy

- The photo is **read on your phone**. Text recognition uses Google ML Kit's
  on-device model.
- The app only talks to your masjid's server, and to GitHub to download the
  directory.
- Your sign-in is kept in your phone's secure storage. Your password is never
  stored on the phone.
- The photo is uploaded only if your masjid's server asks for it, so the
  masjid can check updates. The times are always sent with the time the photo
  was taken.
