namespace Singularity.Apps.Printers {

    internal class PrintersIntents : Object {

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key).strip() : "";
        }

        private static string status_id(Print.PrinterStatus s) {
            switch (s) {
                case Print.PrinterStatus.PRINTING: return "printing";
                case Print.PrinterStatus.PAUSED: return "paused";
                case Print.PrinterStatus.OFFLINE: return "offline";
                case Print.PrinterStatus.ATTENTION: return "needs_attention";
                case Print.PrinterStatus.REJECTING: return "not_accepting";
                default: return "ready";
            }
        }

        private static string job_state_id(Print.JobState s) {
            switch (s) {
                case Print.JobState.HELD: return "held";
                case Print.JobState.PROCESSING: return "printing";
                case Print.JobState.STOPPED: return "stopped";
                case Print.JobState.CANCELED: return "cancelled";
                case Print.JobState.ABORTED: return "failed";
                case Print.JobState.COMPLETED: return "completed";
                default: return "waiting";
            }
        }

        private static async Print.Printer find(Print.PrinterBackend backend, string wanted) throws Error {
            var list = yield backend.list_printers();
            if (wanted == "") {
                foreach (var p in list) if (p.is_default && !p.is_pdf) return p;
                Print.Printer? only = null;
                int real = 0;
                foreach (var p in list) if (!p.is_pdf) { only = p; real++; }
                if (real == 1) return only;
                throw new IOError.INVALID_ARGUMENT(real == 0 ? "there is no printer set up" : "there is no default printer; name one from printers_list");
            }
            string w = wanted.casefold();
            foreach (var p in list) if (p.name.casefold() == w) return p;
            Print.Printer? match = null;
            foreach (var p in list) {
                if (p.display_name.casefold() != w) continue;
                if (match != null) throw new IOError.INVALID_ARGUMENT("more than one printer is called %s; use its name from printers_list", wanted);
                match = p;
            }
            if (match != null) return match;
            throw new IOError.NOT_FOUND("no printer %s; see printers_list", wanted);
        }

        private static void printer(Json.Builder b, Print.Printer p) {
            b.begin_object();
            b.set_member_name("name").add_string_value(p.name);
            b.set_member_name("display_name").add_string_value(p.display_name);
            b.set_member_name("status").add_string_value(status_id(p.status));
            b.set_member_name("status_text").add_string_value(p.status_text());
            if (p.is_default) b.set_member_name("default").add_boolean_value(true);
            if (p.is_pdf) b.set_member_name("saves_pdf").add_boolean_value(true);
            if (p.location != "") b.set_member_name("location").add_string_value(p.location);
            if (p.make_model != "") b.set_member_name("model").add_string_value(p.make_model);
            if (p.queued_jobs > 0) b.set_member_name("queued_jobs").add_int_value(p.queued_jobs);
            if (p.markers.size > 0) {
                b.set_member_name("supplies").begin_array();
                foreach (var m in p.markers) {
                    b.begin_object();
                    b.set_member_name("name").add_string_value(m.name);
                    if (m.level >= 0) b.set_member_name("level_percent").add_int_value(m.level);
                    b.set_member_name("low").add_boolean_value(m.low);
                    b.end_object();
                }
                b.end_array();
            }
            b.end_object();
        }

        private static void job(Json.Builder b, Print.JobInfo j) {
            b.begin_object();
            b.set_member_name("id").add_int_value(j.id);
            b.set_member_name("title").add_string_value(j.title);
            b.set_member_name("printer").add_string_value(j.printer);
            b.set_member_name("state").add_string_value(job_state_id(j.state));
            string why = PrintersApp.job_reason(j);
            if (why != "") b.set_member_name("reason").add_string_value(why);
            if (j.pages_total > 0) b.set_member_name("pages").add_string_value("%d of %d".printf(j.pages_done, j.pages_total));
            if (j.created > 0) b.set_member_name("created").add_string_value(new DateTime.from_unix_local(j.created).format_iso8601());
            b.end_object();
        }

        private static async void list(PrintersApp app, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var backend = Print.PrinterBackend.get_default();
                var all = yield backend.list_printers();
                var b = new Json.Builder();
                b.begin_array();
                foreach (var p in all) {
                    if (!p.is_pdf) yield backend.fill_markers(p);
                    printer(b, p);
                }
                b.end_array();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void jobs(PrintersApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var backend = Print.PrinterBackend.get_default();
                string? name = null;
                if (text(args, "printer") != "") name = (yield find(backend, text(args, "printer"))).name;
                bool done = args.has_member("finished") && args.get_boolean_member("finished");
                var all = yield backend.list_jobs(name, done);
                var b = new Json.Builder();
                b.begin_array();
                int n = 0;
                foreach (var j in all) {
                    if (n++ == 50) break;
                    job(b, j);
                }
                b.end_array();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static string mime_for(string path) throws Error {
            var info = File.new_for_path(path).query_info(FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE);
            string type = ContentType.get_mime_type(info.get_content_type()) ?? "application/octet-stream";
            if (type == "application/pdf" || type == "text/plain" || type == "image/jpeg" || type == "image/png" || type == "application/postscript") return type;
            throw new IOError.NOT_SUPPORTED("%s files are not printed directly; open the file in its app and print from there", type);
        }

        private static async void print(PrintersApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                string path = text(args, "path");
                if (path.has_prefix("~/")) path = Environment.get_home_dir() + path.substring(1);
                if (path == "" || !FileUtils.test(path, FileTest.IS_REGULAR)) throw new IOError.NOT_FOUND("no file at %s", path);
                string mime = mime_for(path);
                var backend = Print.PrinterBackend.get_default();
                var p = yield find(backend, text(args, "printer"));
                if (p.is_pdf) throw new IOError.INVALID_ARGUMENT("%s only saves PDFs; choose a real printer", p.display_name);
                if (p.status == Print.PrinterStatus.REJECTING) throw new IOError.FAILED("%s is not accepting documents", p.display_name);
                var options = new Print.JobOptions();
                options.printer = p.name;
                if (args.has_member("copies")) options.copies = (int) args.get_int_member("copies").clamp(1, 99);
                if (text(args, "pages") != "") {
                    options.range_mode = Print.RangeMode.CUSTOM;
                    options.ranges = text(args, "pages");
                }
                Print.PrinterCapabilities? caps = null;
                try {
                    caps = yield backend.capabilities(p.name);
                } catch (Error e) {
                }
                string title = text(args, "title") != "" ? text(args, "title") : Path.get_basename(path);
                int id = yield backend.submit(p.name, path, title, options, caps, mime);
                if (id <= 0) throw new IOError.FAILED("the printer did not take the document");
                app.activate_action("watch-job", new Variant("(sis)", p.name, id, title));
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("job").add_int_value(id);
                b.set_member_name("printer").add_string_value(p.display_name);
                b.set_member_name("copies").add_int_value(options.copies);
                if (p.status != Print.PrinterStatus.READY && p.status != Print.PrinterStatus.PRINTING) b.set_member_name("warning").add_string_value(p.status_text());
                b.set_member_name("undo").add_string_value("printers_cancel_job with job %d while it is still waiting".printf(id));
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void cancel(PrintersApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                if (!args.has_member("job")) throw new IOError.INVALID_ARGUMENT("give the job number from printers_jobs");
                int id = (int) args.get_int_member("job");
                var backend = Print.PrinterBackend.get_default();
                Print.JobInfo? found = null;
                foreach (var j in yield backend.list_jobs(null, false)) if (j.id == id) found = j;
                if (found == null) throw new IOError.NOT_FOUND("job %d is not waiting or printing", id);
                yield backend.cancel_job(id);
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("cancelled").add_int_value(id);
                b.set_member_name("title").add_string_value(found.title);
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void pause(PrintersApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var backend = Print.PrinterBackend.get_default();
                if (!backend.can(Print.BackendFeature.PAUSE)) throw new IOError.NOT_SUPPORTED("this print system cannot pause printers");
                var p = yield find(backend, text(args, "printer"));
                bool paused = !args.has_member("paused") || args.get_boolean_member("paused");
                yield backend.set_paused(p.name, paused);
                var after = yield backend.get_printer(p.name);
                bool now = after != null && after.status == Print.PrinterStatus.PAUSED;
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("printer").add_string_value(p.display_name);
                b.set_member_name("paused").add_boolean_value(now);
                if (now != paused) b.set_member_name("verified").add_boolean_value(false);
                b.set_member_name("undo").add_string_value("printers_pause with paused %s".printf(paused ? "false" : "true"));
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void make_default(PrintersApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                var backend = Print.PrinterBackend.get_default();
                string? before = yield backend.default_printer();
                var p = yield find(backend, text(args, "printer"));
                if (p.is_pdf) throw new IOError.INVALID_ARGUMENT("the PDF printer cannot be the default");
                yield backend.set_default(p.name);
                string? after = yield backend.default_printer();
                var b = new Json.Builder();
                b.begin_object();
                b.set_member_name("default").add_string_value(p.display_name);
                if (after != p.name) b.set_member_name("verified").add_boolean_value(false);
                if (before != null && before != "" && before != p.name) b.set_member_name("undo").add_string_value("printers_set_default with printer " + before);
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        internal static void install(PrintersApp app) {
            var agent = app.agent;
            agent.add_async_intent("printers_list", "The printers set up on this computer, whether each is ready, paused or needs attention, and their ink or toner levels.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args, reply) => {
                    list.begin(app, (owned) reply);
                });
            agent.add_async_intent("printers_jobs", "Documents waiting or printing (or, with finished, the recent ones that are done), optionally for one printer.",
                "{\"type\":\"object\",\"properties\":{\"printer\":{\"type\":\"string\"},\"finished\":{\"type\":\"boolean\"}}}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    jobs.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("printers_print", "Print a PDF, text, PostScript, JPEG or PNG file on a printer (the default one when left out). pages is like 1-3,5.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"printer\":{\"type\":\"string\"},\"copies\":{\"type\":\"integer\"},\"pages\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    print.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("printers_cancel_job", "Cancel a document that is waiting or printing.",
                "{\"type\":\"object\",\"properties\":{\"job\":{\"type\":\"integer\"}},\"required\":[\"job\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => {
                    cancel.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("printers_pause", "Pause a printer so documents wait in its queue, or resume it with paused false.",
                "{\"type\":\"object\",\"properties\":{\"printer\":{\"type\":\"string\"},\"paused\":{\"type\":\"boolean\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    pause.begin(app, args, (owned) reply);
                });
            agent.add_async_intent("printers_set_default", "Make a printer the one used when no printer is chosen.",
                "{\"type\":\"object\",\"properties\":{\"printer\":{\"type\":\"string\"}},\"required\":[\"printer\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    make_default.begin(app, args, (owned) reply);
                });
        }
    }
}
