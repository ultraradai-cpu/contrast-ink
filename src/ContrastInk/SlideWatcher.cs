using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Threading;

namespace ContrastInk;

/// <summary>
/// Which PowerPoint slide is showing, so each slide can keep its own marks.
/// Asks a running PowerPoint (desktop Office) through its automation interface, a few times a second, on its own
/// thread: a busy PowerPoint can take a moment to answer and must never freeze the drawing layer.
/// The answer is "file#position#slide number" during a slide show, and "" when no slide show is running.
/// </summary>
sealed class SlideWatcher
{
    // PowerPoint.Application. Asked by its class id rather than its name, so nothing has to be looked up in the registry.
    static readonly Guid PowerPoint = new("91493441-5A91-11CF-8700-00AA0060263B");
    [DllImport("oleaut32.dll")] static extern int GetActiveObject(ref Guid clsid, IntPtr reserved, [MarshalAs(UnmanagedType.IUnknown)] out object? obj);

    readonly Dispatcher ui;
    volatile string current = "";
    readonly HashSet<string> logged = new();

    /// <summary>The slide showing now ("" for none), as last read.</summary>
    public string Current => current;

    /// <summary>The slide changed (raised on the UI thread). "" means no slide show.</summary>
    public event Action<string>? Changed;

    public SlideWatcher(Dispatcher ui)
    {
        this.ui = ui;
        new Thread(Loop) { IsBackground = true, Name = "PowerPoint slide watcher" }.Start();
    }

    void Loop()
    {
        while (true)
        {
            string? now;
            // any other failure from PowerPoint must not end the app mid-lecture (an error on this thread would):
            // treated as "PowerPoint didn't answer", logged once per kind
            try { now = Read(); }
            catch (Exception e)
            {
                if (logged.Add("unexpected " + e.GetType().Name)) App.Log(e);
                now = null;
            }
            if (now != null && now != current)
            {
                current = now;
                ui.BeginInvoke(() => Changed?.Invoke(now));
            }
            Thread.Sleep(250);
        }
    }

    /// <summary>The slide showing now; "" for no slide show; null when PowerPoint didn't answer (busy): nothing changes then.</summary>
    string? Read()
    {
        var id = PowerPoint;
        if (GetActiveObject(ref id, IntPtr.Zero, out var app) != 0 || app == null) return "";   // PowerPoint isn't running
        var held = new List<object> { app };
        try
        {
            var shows = Get(app, "SlideShowWindows", held);
            if (Convert.ToInt32(Get(shows, "Count", held)) < 1) return "";
            var show = Call(shows, "Item", held, 1);
            var view = Get(show, "View", held);
            int position = Convert.ToInt32(Get(view, "CurrentShowPosition", held));
            string file = Convert.ToString(Get(Get(show, "Presentation", held), "FullName", held)) ?? "";
            // the slide's own number, for chapter names: with hidden slides or a custom show the position in the show
            // differs ("Slide 5" for what PowerPoint calls slide 6). The black "end of slide show" screen has no slide:
            // the position stands in for it.
            int number = position;
            try { number = Convert.ToInt32(Get(Get(view, "Slide", held), "SlideNumber", held)); }
            catch (Exception e) when (e is COMException or TargetInvocationException or InvalidCastException or MissingMemberException or FormatException) { }
            // "file#position#number": each position keeps its own marks; the last part names the chapter (Obs.SlideNumber)
            return file + "#" + position + "#" + number;
        }
        catch (Exception e) when (e is COMException or TargetInvocationException or InvalidCastException or MissingMemberException or FormatException)
        {
            // PowerPoint busy (a dialog open, saving) or the show just ending. Unknown is not "a new slide": keep the
            // marks where they are. Logged once per kind, not four times a second.
            var inner = (e as TargetInvocationException)?.InnerException ?? e;
            if (logged.Add(inner.GetType().Name + (inner as COMException)?.ErrorCode)) App.Log(inner);
            return null;
        }
        finally
        {
            // every reference let go at once: a reference kept by us would keep PowerPoint running after it is closed
            foreach (var o in held) if (Marshal.IsComObject(o)) Marshal.ReleaseComObject(o);
        }
    }

    static object Get(object o, string name, List<object> held) => Keep(o.GetType().InvokeMember(name, BindingFlags.GetProperty, null, o, null), held);
    static object Call(object o, string name, List<object> held, params object[] args) => Keep(o.GetType().InvokeMember(name, BindingFlags.InvokeMethod, null, o, args), held);
    static object Keep(object? o, List<object> held)
    {
        if (o == null) throw new InvalidCastException("PowerPoint returned nothing");
        held.Add(o);
        return o;
    }
}
