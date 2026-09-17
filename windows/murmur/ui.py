"""The tray icon, the main window and the floating pill.

Tkinter, because it ships with Python and therefore adds nothing to the
download, and because four panes of labels and checkboxes do not justify a
GUI toolkit of their own.

Threading rule: every Tk call happens on the main thread. The controller
signals from its worker threads by putting a token on a queue that the main
thread drains on a timer, which avoids the well-known sharp edges of calling
into Tk from elsewhere.
"""

from __future__ import annotations

import queue
import threading
import tkinter as tk
import webbrowser
from tkinter import ttk

from . import asr, paths, polish, winapi
from .audio import input_devices
from .log import log

ACCENT = "#c0392b"


def make_image(size: int = 64):
    """The tray and window icon: a dark rounded square with a microphone on
    it, drawn rather than shipped so there is no binary asset to keep."""
    from PIL import Image, ImageDraw

    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    unit = size / 64
    draw.rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=14 * unit, fill=(30, 32, 38, 255)
    )
    draw.rounded_rectangle(
        [26 * unit, 14 * unit, 38 * unit, 36 * unit], radius=6 * unit, fill=(236, 238, 242, 255)
    )
    draw.arc(
        [20 * unit, 24 * unit, 44 * unit, 44 * unit],
        start=0,
        end=180,
        fill=(236, 238, 242, 255),
        width=int(3 * unit),
    )
    draw.line(
        [32 * unit, 44 * unit, 32 * unit, 50 * unit], fill=(236, 238, 242, 255), width=int(3 * unit)
    )
    return image


def save_ico(path: str) -> None:
    """Writes the multi-resolution .ico the installer and the exe use."""
    make_image(256).save(path, sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])


class Pill:
    """The capsule that appears at the bottom of the screen while dictating.

    It is created once and then only faded in and out. A window that is
    mapped and unmapped can take the foreground with it, and taking the
    foreground is exactly what must not happen here: the paste goes to
    whichever window has focus.
    """

    def __init__(self, root: tk.Tk) -> None:
        self.window = tk.Toplevel(root)
        self.window.overrideredirect(True)
        self.window.attributes("-topmost", True)
        self.window.attributes("-alpha", 0.0)
        try:
            self.window.attributes("-disabled", True)  # Windows: never focusable
        except tk.TclError:
            pass
        self.window.configure(bg="#1e2026")

        self.dot = tk.Canvas(
            self.window, width=14, height=14, bg="#1e2026", highlightthickness=0
        )
        self.dot.pack(side="left", padx=(16, 8), pady=12)
        self._circle = self.dot.create_oval(2, 2, 12, 12, fill=ACCENT, outline="")

        self.label = tk.Label(
            self.window, text="Listening", bg="#1e2026", fg="#eceef2",
            font=("Segoe UI", 11), padx=0,
        )
        self.label.pack(side="left", padx=(0, 18), pady=12)

        self.window.update_idletasks()
        self._place()
        self._pulse_on = False

    def _place(self) -> None:
        self.window.update_idletasks()
        width = max(self.window.winfo_reqwidth(), 150)
        height = self.window.winfo_reqheight()
        screen_width = self.window.winfo_screenwidth()
        screen_height = self.window.winfo_screenheight()
        x = (screen_width - width) // 2
        y = screen_height - height - 110
        self.window.geometry(f"{width}x{height}+{x}+{y}")

    def show(self, mode: str) -> None:
        if mode == "listening":
            self.label.configure(text="Listening")
            self.dot.itemconfigure(self._circle, fill=ACCENT)
            if not self._pulse_on:
                self._pulse_on = True
                self._pulse(True)
        else:
            self.label.configure(text="Writing it up")
            self.dot.itemconfigure(self._circle, fill="#f0a020")
            self._pulse_on = False
        self._place()
        self.window.attributes("-alpha", 0.94)
        self.window.lift()

    def hide(self) -> None:
        self._pulse_on = False
        self.window.attributes("-alpha", 0.0)

    def _pulse(self, bright: bool) -> None:
        if not self._pulse_on:
            return
        self.dot.itemconfigure(self._circle, fill=ACCENT if bright else "#5a2a24")
        self.window.after(480, lambda: self._pulse(not bright))


class MainWindow:
    """Status, Settings, History and Dictionary, the same four panes as the
    Mac build."""

    def __init__(self, root: tk.Tk, app) -> None:
        self.root = root
        self.app = app
        root.title("Murmur")
        root.geometry("620x520")
        root.minsize(560, 460)
        try:
            root.iconphoto(True, self._icon_photo())
        except Exception:
            pass

        style = ttk.Style()
        if "vista" in style.theme_names():
            style.theme_use("vista")

        self.notebook = ttk.Notebook(root)
        self.notebook.pack(fill="both", expand=True, padx=12, pady=12)

        self.status_tab = ttk.Frame(self.notebook, padding=16)
        self.settings_tab = ttk.Frame(self.notebook, padding=16)
        self.history_tab = ttk.Frame(self.notebook, padding=16)
        self.dictionary_tab = ttk.Frame(self.notebook, padding=16)
        self.notebook.add(self.status_tab, text="Status")
        self.notebook.add(self.settings_tab, text="Settings")
        self.notebook.add(self.history_tab, text="History")
        self.notebook.add(self.dictionary_tab, text="Dictionary")

        self._build_status()
        self._build_settings()
        self._build_history()
        self._build_dictionary()

        root.protocol("WM_DELETE_WINDOW", self.hide)

    def _icon_photo(self):
        from PIL import ImageTk

        self._photo = ImageTk.PhotoImage(make_image(64))
        return self._photo

    # MARK: - Status

    def _build_status(self) -> None:
        frame = self.status_tab
        self.headline = ttk.Label(frame, text="Starting…", font=("Segoe UI", 15, "bold"))
        self.headline.pack(anchor="w")
        self.subhead = ttk.Label(frame, text="", foreground="#555", wraplength=540, justify="left")
        self.subhead.pack(anchor="w", pady=(4, 14))

        self.progress = ttk.Progressbar(frame, mode="determinate", length=540)
        self.progress_label = ttk.Label(frame, text="", foreground="#555")

        self.checks = ttk.Frame(frame)
        self.checks.pack(fill="x", pady=(4, 10))
        self.check_labels = {}
        for key, caption in (
            ("hotkey", "Push-to-talk key"),
            ("speech", "Speech recognition"),
            ("polish", "Polishing model"),
            ("microphone", "Microphone"),
        ):
            row = ttk.Frame(self.checks)
            row.pack(fill="x", pady=2)
            ttk.Label(row, text=caption, width=20).pack(side="left")
            value = ttk.Label(row, text="…", foreground="#555")
            value.pack(side="left")
            self.check_labels[key] = value

        self.problem = ttk.Label(frame, text="", foreground=ACCENT, wraplength=540, justify="left")
        self.problem.pack(anchor="w", pady=(8, 0))

        buttons = ttk.Frame(frame)
        buttons.pack(side="bottom", anchor="w", pady=(12, 0))
        # Shown only when a model failed to arrive, which on a first run is
        # nearly always a connection that dropped part-way through.
        self.retry_button = ttk.Button(buttons, text="Try again", command=self._retry)
        self.log_button = ttk.Button(buttons, text="Open the log", command=self._open_log)
        self.log_button.pack(side="left")
        ttk.Button(buttons, text="Quit Murmur", command=self.app_quit).pack(side="left", padx=8)

    def _retry(self) -> None:
        self.retry_button.pack_forget()
        self.app.reload_models()

    def _open_log(self) -> None:
        try:
            webbrowser.open(str(paths.LOG_FILE))
        except Exception as error:
            log(f"could not open the log: {error!r}")

    def app_quit(self) -> None:
        self.root.event_generate("<<MurmurQuit>>", when="tail")

    # MARK: - Settings

    def _build_settings(self) -> None:
        frame = self.settings_tab
        row = 0

        def label(text: str, hint: str = "") -> None:
            nonlocal row
            ttk.Label(frame, text=text, font=("Segoe UI", 10, "bold")).grid(
                row=row, column=0, sticky="w", pady=(10, 0)
            )
            row += 1
            if hint:
                ttk.Label(frame, text=hint, foreground="#666", wraplength=520, justify="left").grid(
                    row=row, column=0, sticky="w"
                )
                row += 1

        settings = self.app.settings

        label(
            "Push-to-talk key",
            "Hold it, speak, let go. Windows keyboards handle fn in firmware and never "
            "report it, so Murmur cannot use the Mac's key.",
        )
        self.hotkey_var = tk.StringVar(
            value=winapi.hotkey_for(settings.hotkey).label
        )
        hotkey_box = ttk.Combobox(
            frame,
            textvariable=self.hotkey_var,
            values=[h.label for h in winapi.HOTKEYS],
            state="readonly",
            width=28,
        )
        hotkey_box.grid(row=row, column=0, sticky="w", pady=(4, 0))
        hotkey_box.bind("<<ComboboxSelected>>", self._on_hotkey_change)
        row += 1

        label("Microphone", "Murmur only holds the microphone while the key is down.")
        self.device_var = tk.StringVar(value=settings.input_device or "System default")
        self.device_box = ttk.Combobox(
            frame, textvariable=self.device_var, state="readonly", width=44
        )
        self.device_box.grid(row=row, column=0, sticky="w", pady=(4, 0))
        self.device_box.bind("<<ComboboxSelected>>", self._on_device_change)
        self.refresh_devices()
        row += 1

        label(
            "Speech model",
            "Larger is more accurate and slower. Changing this downloads the new model.",
        )
        self.whisper_var = tk.StringVar(value=asr.MODELS.get(settings.whisper_model, "Small (recommended)"))
        whisper_box = ttk.Combobox(
            frame, textvariable=self.whisper_var, values=list(asr.MODELS.values()),
            state="readonly", width=36,
        )
        whisper_box.grid(row=row, column=0, sticky="w", pady=(4, 0))
        whisper_box.bind("<<ComboboxSelected>>", self._on_whisper_change)
        row += 1

        label(
            "Polishing model",
            "Tidies the transcript: fillers out, spoken corrections applied, emails laid "
            "out. Automatic picks by how much memory and how many cores this PC has.",
        )
        self.polish_var = tk.StringVar(value=self._polish_label(settings.polish_model))
        polish_box = ttk.Combobox(
            frame,
            textvariable=self.polish_var,
            values=["Automatic"] + [m.label for m in polish.MODELS.values()],
            state="readonly",
            width=36,
        )
        polish_box.grid(row=row, column=0, sticky="w", pady=(4, 0))
        polish_box.bind("<<ComboboxSelected>>", self._on_polish_change)
        row += 1

        self.launch_var = tk.BooleanVar(value=winapi.get_launch_at_login())
        ttk.Checkbutton(
            frame,
            text="Start Murmur when I sign in",
            variable=self.launch_var,
            command=self._on_launch_change,
        ).grid(row=row, column=0, sticky="w", pady=(16, 0))

    @staticmethod
    def _polish_label(key: str) -> str:
        choice = polish.MODELS.get(key)
        return choice.label if choice else "Automatic"

    def refresh_devices(self) -> None:
        names = ["System default"] + [d["name"] for d in input_devices()]
        self.device_box.configure(values=names)

    def _on_hotkey_change(self, _event=None) -> None:
        for hotkey in winapi.HOTKEYS:
            if hotkey.label == self.hotkey_var.get():
                self.app.apply_settings(hotkey=hotkey.key)
                return

    def _on_device_change(self, _event=None) -> None:
        chosen = self.device_var.get()
        self.app.apply_settings(input_device="" if chosen == "System default" else chosen)

    def _on_whisper_change(self, _event=None) -> None:
        for key, caption in asr.MODELS.items():
            if caption == self.whisper_var.get():
                self.app.apply_settings(whisper_model=key)
                return

    def _on_polish_change(self, _event=None) -> None:
        chosen = self.polish_var.get()
        if chosen == "Automatic":
            self.app.apply_settings(polish_model="auto")
            return
        for key, choice in polish.MODELS.items():
            if choice.label == chosen:
                self.app.apply_settings(polish_model=key)
                return

    def _on_launch_change(self) -> None:
        self.app.apply_settings(launch_at_login=self.launch_var.get())

    # MARK: - History

    def _build_history(self) -> None:
        frame = self.history_tab
        ttk.Label(
            frame,
            text="The last 100 dictations, kept on this PC. Handy when a paste lands "
            "somewhere unexpected.",
            foreground="#666",
            wraplength=540,
            justify="left",
        ).pack(anchor="w", pady=(0, 8))

        self.history_list = tk.Listbox(frame, height=14, activestyle="none")
        self.history_list.pack(fill="both", expand=True)
        self.history_list.bind("<Double-Button-1>", self._copy_history_entry)

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=(8, 0))
        ttk.Label(buttons, text="Double-click an entry to copy it.", foreground="#666").pack(side="left")
        ttk.Button(buttons, text="Clear", command=self._clear_history).pack(side="right")

    def _copy_history_entry(self, _event=None) -> None:
        selection = self.history_list.curselection()
        if not selection:
            return
        entry = self.app.history.entries[selection[0]]
        self.root.clipboard_clear()
        self.root.clipboard_append(entry.text)

    def _clear_history(self) -> None:
        self.app.history.clear()
        self.refresh_history()

    def refresh_history(self) -> None:
        self.history_list.delete(0, tk.END)
        for entry in self.app.history.entries:
            when = entry.date[11:16] if len(entry.date) > 15 else entry.date
            single_line = " ".join(entry.text.split())
            self.history_list.insert(tk.END, f"{when}  {single_line[:90]}")

    # MARK: - Dictionary

    def _build_dictionary(self) -> None:
        frame = self.dictionary_tab
        ttk.Label(
            frame,
            text="Names and jargon the recogniser gets wrong, one per line. They are "
            "given to the recogniser as hints, and their spelling is enforced on the "
            "result.",
            foreground="#666",
            wraplength=540,
            justify="left",
        ).pack(anchor="w", pady=(0, 8))

        self.dictionary_text = tk.Text(frame, height=14, wrap="word", font=("Segoe UI", 10))
        self.dictionary_text.pack(fill="both", expand=True)
        self.dictionary_text.insert("1.0", self.app.dictionary.text)

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=(8, 0))
        ttk.Button(buttons, text="Save", command=self._save_dictionary).pack(side="right")

    def _save_dictionary(self) -> None:
        self.app.dictionary.set_text(self.dictionary_text.get("1.0", tk.END).strip())

    # MARK: - Redraw

    def refresh(self) -> None:
        status = self.app.status
        downloading = status.download_progress is not None
        stalled = not downloading and not status.is_ready and (
            "unavailable" in status.speech.lower()
            or "could not" in status.polish.lower()
            or "unavailable" in status.polish.lower()
        )

        if downloading:
            self.headline.configure(text="Setting Murmur up")
            self.subhead.configure(
                text="Downloading the models Murmur runs on. This happens once. "
                "Afterwards it never needs the internet again."
            )
            self.progress.pack(anchor="w", pady=(4, 2))
            self.progress_label.pack(anchor="w", pady=(0, 10))
            self.progress.configure(value=status.download_progress * 100)
            self.progress_label.configure(text=status.download_label)
        else:
            self.progress.pack_forget()
            self.progress_label.pack_forget()
            key = winapi.hotkey_for(self.app.settings.hotkey).label
            if status.is_ready:
                self.headline.configure(text="Ready")
                self.subhead.configure(text=f"Hold {key}, speak, and let go.")
            elif stalled:
                # Say which half is missing. Losing the polishing model still
                # leaves a working dictation tool, and claiming otherwise
                # would send someone hunting for a problem they do not have.
                self.headline.configure(text="Something is missing")
                if "ready" in status.speech.lower():
                    self.subhead.configure(
                        text=f"Dictation works: hold {key} and speak. But the polishing "
                        "model did not load, so text is inserted as recognised, without "
                        "fillers removed or spoken corrections applied."
                    )
                else:
                    self.subhead.configure(
                        text="Murmur cannot dictate until the speech model has loaded."
                    )
            else:
                self.headline.configure(text="Getting ready…")
                self.subhead.configure(text="Murmur can dictate as soon as both models are loaded.")

        key_label = winapi.hotkey_for(self.app.settings.hotkey).label
        self.check_labels["hotkey"].configure(
            text=f"Listening for {key_label}" if status.hotkey_ready else "Not started"
        )
        self.check_labels["speech"].configure(text=status.speech)
        self.check_labels["polish"].configure(text=status.polish)
        self.check_labels["microphone"].configure(text=status.microphone)
        self.problem.configure(text=status.last_problem or "")

        if stalled:
            self.retry_button.pack(side="left", padx=(0, 8), before=self.log_button)
        else:
            self.retry_button.pack_forget()

        self.refresh_history()

    def show(self) -> None:
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()
        self.refresh_devices()
        self.refresh()

    def hide(self) -> None:
        self.root.withdraw()


class Tray:
    """The notification-area icon. pystray runs its own message loop, so it
    gets its own thread."""

    def __init__(self, on_open, on_quit) -> None:
        self.on_open = on_open
        self.on_quit = on_quit
        self.icon = None

    def start(self) -> None:
        import pystray

        menu = pystray.Menu(
            pystray.MenuItem("Open Murmur", lambda: self.on_open(), default=True),
            pystray.MenuItem("Quit Murmur", lambda: self.on_quit()),
        )
        self.icon = pystray.Icon("Murmur", make_image(64), "Murmur", menu)
        threading.Thread(target=self.icon.run, name="murmur-tray", daemon=True).start()

    def stop(self) -> None:
        if self.icon:
            try:
                self.icon.stop()
            except Exception:
                pass


def run(app) -> None:
    """Owns the main thread for the life of the app.

    Everything that arrives from another thread (the controller's status
    changes, the tray's menu clicks) comes in on one queue that the main
    thread drains on a timer. Nothing else touches Tk.
    """
    root = tk.Tk()
    root.withdraw()
    window = MainWindow(root, app)
    pill = Pill(root)

    signals: queue.Queue = queue.Queue()
    app.on_change = lambda: signals.put(("refresh", None))
    app.on_pill = lambda mode: signals.put(("pill", mode))

    tray = Tray(
        on_open=lambda: signals.put(("open", None)),
        on_quit=lambda: signals.put(("quit", None)),
    )

    def quit_app() -> None:
        log("quitting")
        app.shutdown()
        tray.stop()
        root.quit()

    def drain() -> None:
        redraw = False
        open_window = False
        pill_mode = ...  # distinct from None, which means "hide it"
        while True:
            try:
                kind, value = signals.get_nowait()
            except queue.Empty:
                break
            if kind == "refresh":
                redraw = True
            elif kind == "pill":
                pill_mode = value
            elif kind == "open":
                open_window = True
            elif kind == "quit":
                quit_app()
                return
        if pill_mode is not ...:
            pill.show(pill_mode) if pill_mode else pill.hide()
        if open_window:
            window.show()
        elif redraw and root.state() != "withdrawn":
            window.refresh()
        root.after(120, drain)

    root.bind("<<MurmurQuit>>", lambda _event: quit_app())
    tray.start()
    root.after(120, drain)
    if app.first_run:
        window.show()

    try:
        root.mainloop()
    except KeyboardInterrupt:
        quit_app()
