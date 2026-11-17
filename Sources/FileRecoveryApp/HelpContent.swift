import Foundation

struct HelpSection: Hashable {
    var heading: String?
    var paragraphs: [String] = []
    var bullets: [String] = []
}

struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let sections: [HelpSection]
}

/// The app's help, written here rather than shipped as a help book so it
/// lives next to the behaviour it describes and is checked by the compiler.
/// Anything said here must match what the tool actually does.
enum HelpContent {
    static let cannotFindID = "cannot-find"

    static let topics: [HelpTopic] = [
        HelpTopic(id: "start", title: "Before You Start", systemImage: "exclamationmark.shield", sections: [
            HelpSection(paragraphs: [
                "A deleted file is not gone at once. Its space is marked as free, and the file stays there until something else is written over it. Recovery works by finding that space before it is reused.",
            ]),
            HelpSection(heading: "Three rules that decide whether recovery works", bullets: [
                "Stop using the drive. Every photo taken, file saved or app installed on it can overwrite what you are trying to get back. Take a card out of the camera.",
                "Recover to a different drive. Saving recovered files onto the drive they came from overwrites the others. The app refuses to do this.",
                "If the drive is failing, copy it first. Use Copy a Drive to read it once into a file, then recover from the file.",
            ]),
            HelpSection(heading: "What costs money", paragraphs: [
                "Scanning and previewing are free, so you can see what can be recovered before you pay. A licence is needed to save recovered files. The other tools do not need one.",
            ]),
            HelpSection(heading: "What this app cannot do", bullets: [
                "Recover from the Mac's internal drive. Modern Macs erase deleted data on the internal drive almost immediately, so there is nothing left to find. The internal drive is not listed.",
                "Recover files that have been overwritten, by this app or any other.",
                "Repair a file that was already damaged before it was deleted.",
            ]),
        ]),
        HelpTopic(id: "recover", title: "Recover Files", systemImage: "arrow.uturn.backward.circle", sections: [
            HelpSection(heading: "1. Choose a source", paragraphs: [
                "Connect the drive or card and choose it from the list. You can also choose a folder, or a drive image made with Copy a Drive.",
                "Drives formatted as ExFAT, FAT32 or NTFS are fully supported: deleted files can come back with their original names and dates. On other formats, including APFS, files are found by their contents only and have no names.",
            ]),
            HelpSection(heading: "2. Set up the scan", bullets: [
                "What to look for: fewer file types make a faster scan and a shorter list.",
                "Quick finds files that are still intact. Deep also tries to rebuild damaged files and can take several times longer.",
                "If the drive is in use by macOS, the app offers to unmount it first so nothing is written to it during the scan.",
            ]),
            HelpSection(paragraphs: [
                "macOS asks for your password when the scan starts, because reading a drive directly needs an administrator's permission. The scan only reads. Nothing on the drive is changed.",
            ]),
            HelpSection(heading: "3. While it runs", bullets: [
                "You can look at the results as they arrive.",
                "Pause and resume at any time.",
                "If you stop the scan, you can resume it later from where it stopped. Save Session in the File menu keeps the results and the place reached, so you can carry on another day.",
                "Parts of a drive that cannot be read are skipped and counted. The scan carries on.",
            ]),
            HelpSection(heading: "4. Review and recover", bullets: [
                "Click a file to preview it. A file that previews correctly will recover correctly.",
                "Use the filters to narrow the list by type, by size, or to files that kept their original name.",
                "\"May be damaged\" marks a file whose end could not be confirmed, or that sits on an unreadable part of the drive. It may open only partly.",
                "Tick the files you want, choose Recover Selected, and pick a folder on a different drive.",
            ]),
            HelpSection(heading: "Names and dates", paragraphs: [
                "Files found through the drive's own records keep their names and dates. Photos found by their contents are named from the date the picture was taken, when the photo records one. On FAT32, a short file name loses its first character when the file is deleted, so it is shown as an underscore.",
            ]),
        ]),
        HelpTopic(id: "image", title: "Copy a Drive", systemImage: "externaldrive.badge.plus", sections: [
            HelpSection(paragraphs: [
                "Copy a Drive reads a whole drive or volume once and saves an exact copy as a single file, called an image. You then recover from the image as often as you like, without touching the drive again.",
            ]),
            HelpSection(heading: "When to use it", bullets: [
                "The drive clicks, disconnects, is very slow, or shows errors. Every extra read risks it failing for good.",
                "You need to give the drive back, or keep using the card.",
            ]),
            HelpSection(heading: "How it works", bullets: [
                "Choose the volume to copy and where to save the image. The image is as large as the drive, and must be saved on a different drive.",
                "Parts that cannot be read are filled with zeros and counted. One bad spot does not stop the copy.",
                "If you stop, or the drive drops out, the part copied so far is kept and can still be scanned.",
                "When it finishes, choose Scan This Image to open it in Recover Files.",
            ]),
            HelpSection(heading: "Good to know", bullets: [
                "Choose a volume rather than the entire drive when you can. A scan of a volume's image can show original file names; an image of an entire drive is searched without them.",
                "A stopped copy cannot be continued. It starts again from the beginning.",
            ]),
        ]),
        HelpTopic(id: "copy", title: "Verified Copy", systemImage: "checkmark.seal", sections: [
            HelpSection(paragraphs: [
                "Verified Copy copies a camera card to one or two drives and then checks every copied file against the original. It exists to answer one question: is it safe to format this card?",
            ]),
            HelpSection(heading: "How it works", bullets: [
                "Choose the card, then one or two folders on other drives.",
                "Each file is copied into a new folder named after the card and today's date. Folders and file dates are kept.",
                "Each copy is then read back from its drive and compared with the original.",
                "Only when every file matches on every drive does the app say the card is safe to format. Otherwise it lists what failed, and those files are still only on the card.",
            ]),
            HelpSection(heading: "Good to know", bullets: [
                "Nothing on the card is changed or removed.",
                "Hidden system files, which macOS adds to cards, are not copied.",
                "A file named SHA256SUMS.txt is saved with each copy. It lets the copy be checked again in future, to confirm nothing has changed.",
                "Two copies on two different drives protect you if one drive fails. A destination on the same drive as the card is refused.",
            ]),
        ]),
        HelpTopic(id: "duplicates", title: "Find Duplicates", systemImage: "square.on.square", sections: [
            HelpSection(paragraphs: [
                "Find Duplicates looks through the folders you choose for files whose contents are exactly the same, whatever they are called and wherever they are.",
            ]),
            HelpSection(heading: "How it works", bullets: [
                "Add one or more folders or drives and start the search. Searching removes nothing.",
                "Results are shown in groups of identical copies. Nothing is marked to begin with.",
                "Tick the copies you do not want, or use the Mark menu to mark every extra copy at once, keeping the oldest or the newest in each group.",
                "Choose Move to Trash and confirm.",
            ]),
            HelpSection(heading: "What keeps you safe", bullets: [
                "Files are moved to the Trash, never deleted outright. You can put them back until you empty the Trash.",
                "One copy in every group always stays. The last copy cannot be marked.",
                "A file that changed after the search is left alone.",
            ]),
            HelpSection(heading: "What is left out", bullets: [
                "Hidden files, and the insides of apps and libraries such as the Photos library.",
                "Photos that only look alike. Two files must be identical byte for byte.",
            ]),
        ]),
        HelpTopic(id: "erase", title: "Secure Erase", systemImage: "lock.shield", sections: [
            HelpSection(paragraphs: [
                "Secure Erase overwrites data on an external drive or card so that recovery tools, including this one, cannot bring it back. It cannot be undone. The Mac's internal drive is never offered.",
            ]),
            HelpSection(heading: "Three ways to erase", bullets: [
                "Erase Free Space destroys files you have already deleted and keeps the files still on the drive. The drive is completely full while it runs.",
                "Shred Files destroys the files and folders you choose. They do not go to the Trash.",
                "Erase Entire Volume destroys everything on the volume and leaves it empty and ready to use. You must type the volume's name to confirm.",
            ]),
            HelpSection(heading: "The recovery check", paragraphs: [
                "After erasing free space or an entire volume, the app scans the drive with its own recovery engine and tells you how many files it can still find. macOS asks for your password for this, and you can skip it.",
            ]),
            HelpSection(heading: "Limits you should know", bullets: [
                "Flash storage (SD cards, USB sticks, SSDs) keeps a small reserve of memory that no software can reach. No app can promise that every trace is gone from flash storage.",
                "Shredding a single file is the weakest of the three on flash storage. To be sure, erase the free space afterwards or erase the entire volume.",
                "After erasing free space, the names of deleted files may still be visible to recovery tools. Their contents cannot be read.",
                "APFS and unformatted drives are not listed. A Windows (NTFS) drive can only be erased as an entire volume.",
            ]),
        ]),
        HelpTopic(id: cannotFindID, title: "Why Can't I Find My File?", systemImage: "questionmark.circle", sections: [
            HelpSection(heading: "Things to try first", bullets: [
                "Run a Deep scan. Quick only finds files that are still intact.",
                "Check which file types were selected for the scan. A type that was not selected is not looked for.",
                "Clear the filters and the file name search above the results. They hide files; they do not remove them.",
                "If the scan was stopped early, resume it. The file may be in the part not yet searched.",
                "Look for the file by its contents, not its name. Many recovered files have lost their names; switch to the gallery and look at the pictures, or filter by size.",
            ]),
            HelpSection(heading: "Reasons a file cannot be recovered", bullets: [
                "It was overwritten. Anything saved to the drive after the file was deleted may have reused its space. This is the most common reason, and it is why you should stop using the drive at once.",
                "The drive erases deleted data itself. SSDs, and some USB sticks and cards, clear deleted space on their own within seconds or minutes. The Mac's internal drive always does.",
                "The file was in pieces. A large file, such as a long video, is often stored in several separate parts. Without the drive's own record of where the parts are, only the first part can be found, and the file is damaged or missing.",
                "The drive was encrypted. Without it being unlocked, its contents look like random data.",
                "The format has limited support. On APFS and Mac OS Extended drives, files are found by their contents only, and only for the file types the app knows.",
                "That part of the drive cannot be read. The scan summary shows how much was unreadable.",
            ]),
            HelpSection(heading: "The file is found but will not open", paragraphs: [
                "A file marked \"May be damaged\" was found but is incomplete: part of it was overwritten, or it was stored in pieces. A photo may show only its top half; a video may not play. Preview a file before you recover it. What you see in the preview is what you will get.",
            ]),
            HelpSection(heading: "The drive was formatted", paragraphs: [
                "Formatting usually replaces only the drive's list of files, not the files themselves, so a scan can often still find them by their contents, without their names. A full erase, or a camera's \"low-level format\", overwrites everything and leaves nothing to find.",
            ]),
        ]),
    ]

    static func topic(_ id: String) -> HelpTopic {
        topics.first { $0.id == id } ?? topics[0]
    }
}
