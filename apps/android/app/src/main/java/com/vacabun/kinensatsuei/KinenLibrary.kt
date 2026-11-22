package com.vacabun.kinensatsuei

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.util.AtomicFile
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale
import java.util.UUID

data class TravelStop(val id: String, val date: String, val time: String?, val title: String, val place: String, val note: String)

data class Note(
    val id: String, val kind: String, val title: String, val startDate: String, val endDate: String?,
    val parentId: String?, val body: String, val mediaIds: List<String>, val itinerary: List<TravelStop>
)

data class Attachment(val relative: String, val sha256: String, val bytes: Long)

data class Medium(
    val id: String, val kind: String, val date: String?, val memberIds: List<String>, val groupId: String?,
    val note: String, val rotation: Int, val original: Attachment, val corrected: Attachment?
)

data class CollectionSubject(val id: String, val name: String)
data class MediaAttribution(val id: String, val isGroup: Boolean)

data class KinenSnapshot(
    val root: File, val notes: List<Note>, val media: List<Medium>, val members: List<CollectionSubject>,
    val groups: List<CollectionSubject>, val drafts: List<Note> = emptyList()
) {
    fun attachment(item: Medium): File {
        val corrected = item.corrected?.let { File(root, it.relative) }
        return corrected?.takeIf(File::isFile) ?: File(root, item.original.relative)
    }

    fun names(item: Medium): List<String> = members.filter { it.id in item.memberIds }.map { it.name } +
        groups.filter { it.id == item.groupId }.map { it.name }
}

class KinenLibrary(context: Context) {
    private val parent = File(context.filesDir, "libraries")
    private val defaults = context.getSharedPreferences("kinen-library", Context.MODE_PRIVATE)
    private val resolver = context.contentResolver
    private val editingSessions = mutableMapOf<String, String>()

    private fun currentFolder(): File {
        val name = defaults.getString("active", "default") ?: "default"
        return File(parent, if (name == "default") name else recordID(name))
    }

    @Synchronized fun current(): KinenSnapshot {
        val folder = currentFolder()
        if (folder.name == "default" && !File(folder, "library.json").isFile) {
            require(folder.mkdirs() || folder.isDirectory)
            val manifest = JSONObject().put("formatVersion", 1).put("libraryId", UUID.randomUUID().toString())
                .put("title", "記念撮影")
            val staged = File(folder, ".manifest")
            staged.writeText(manifest.toString(2))
            check(staged.renameTo(File(folder, "library.json")))
        }
        return read(folder)
    }

    @Synchronized fun restore(tree: Uri): KinenSnapshot {
        require(parent.mkdirs() || parent.isDirectory)
        val stage = File(parent, ".incoming-${UUID.randomUUID()}")
        require(stage.mkdir())
        try {
            val source = Folder(resolver, tree, DocumentsContract.getTreeDocumentId(tree))
            source.file("library.json").copyTo(File(stage, "library.json"), maximumMetadata)
            verifyManifest(File(stage, "library.json"))
            var records = 0
            for (name in listOf("members", "groups", "media", "entries")) {
                val directory = source.directory(name) ?: continue
                val target = File(stage, name).apply { check(mkdir()) }
                for ((filename, doc) in directory.contents) {
                    if (filename == ".DS_Store") continue
                    require(++records <= 100_000) { "资料库包含过多记录。" }
                    if (name == "entries") {
                        recordID(filename)
                        val entry = doc.asFolder()
                        val output = File(target, filename).apply { check(mkdir()) }
                        for (child in listOf("entry.json", "body.md")) {
                            entry.file(child).copyTo(File(output, child), maximumMetadata)
                        }
                    } else {
                        require(filename.endsWith(".json")) { "资料库目录格式不正确。" }
                        recordID(filename.removeSuffix(".json"))
                        doc.copyTo(File(target, filename), maximumMetadata)
                    }
                }
            }
            val snapshot = read(stage)
            val copied = mutableMapOf<String, Attachment>()
            for (asset in snapshot.media.flatMap { listOfNotNull(it.original, it.corrected) }) {
                val previous = copied[asset.relative]
                require(previous == null || previous == asset) { "媒体记录不一致。" }
                if (previous != null) continue
                val parts = asset.relative.split("/")
                var folder: Folder? = source
                for (segment in parts.dropLast(1)) folder = folder?.directory(segment)
                val file = folder?.contents?.get(parts.last()) ?: continue
                val destination = File(stage, asset.relative)
                check(destination.parentFile?.mkdirs() == true || destination.parentFile?.isDirectory == true)
                file.copyTo(destination, asset.bytes, asset)
                copied[asset.relative] = asset
            }
            val name = UUID.randomUUID().toString()
            val destination = File(parent, name)
            check(stage.renameTo(destination)) { "无法安装已校验的资料库。" }
            val restored = snapshot.copy(root = destination)
            check(defaults.edit().putString("active", name).commit())
            return restored
        } finally {
            if (stage.exists()) stage.deleteRecursively()
        }
    }

    @Synchronized fun useDefault(): KinenSnapshot {
        check(defaults.edit().remove("active").commit())
        return current()
    }

    @Synchronized fun addSubject(name: String, isGroup: Boolean): MediaAttribution {
        val label = name.trim()
        require(label.isNotEmpty()) { "请填写名称。" }
        val root = currentFolder()
        val id = UUID.randomUUID().toString()
        val directory = File(root, if (isGroup) "groups" else "members")
        check(directory.mkdirs() || directory.isDirectory)
        val time = now()
        val record = JSONObject().put("id", id).put("name", label).put("createdAt", time)
        if (!isGroup) record.put("updatedAt", time).put("aliases", JSONArray()).put("archived", false)
        writeJson(File(directory, "$id.json"), record)
        return MediaAttribution(id, isGroup)
    }

    fun mediaType(uri: Uri): String? = resolver.getType(uri)?.takeIf {
        it.startsWith("image/") || it.startsWith("video/")
    }

    @Synchronized fun importMedia(uri: Uri, mimeType: String, kind: String, captureDate: String?,
                                  attribution: MediaAttribution?, note: String) {
        val root = currentFolder()
        val id = UUID.randomUUID().toString()
        val date = captureDate?.let { LocalDate.parse(it).toString() }
        require(kind in setOf("cheki", "photo", "portrait", "video") &&
            (kind == "video" && mimeType.startsWith("video/") || kind != "video" && mimeType.startsWith("image/"))) {
            "请选择照片或视频。"
        }
        if (kind == "cheki") require(attribution != null && date != null) { "请选择拍立得归属和日期。" }
        if (attribution != null) {
            val folder = if (attribution.isGroup) "groups" else "members"
            require(File(root, "$folder/${recordID(attribution.id)}.json").isFile) { "归属记录不可用。" }
        }
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)?.lowercase(Locale.ROOT)
            ?.takeIf { it.matches(Regex("[a-z0-9]{1,12}")) }
        val suffix = extension?.let { ".$it" }.orEmpty()
        val storedName = if (kind == "cheki") "${requireNotNull(attribution).id}_${date}_$id$suffix" else null
        val stage = File(root, ".import-$id")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var size = 0L
            val input = requireNotNull(resolver.openInputStream(uri)) { "无法读取媒体文件。" }
            input.use { source ->
                stage.outputStream().use { target ->
                    val bytes = ByteArray(128 * 1024)
                    while (true) {
                        val count = source.read(bytes)
                        if (count < 0) break
                        size += count
                        digest.update(bytes, 0, count)
                        target.write(bytes, 0, count)
                    }
                }
            }
            require(size > 0) { "媒体文件为空。" }
            val hash = digest.digest().joinToString("") { "%02x".format(it) }
            val holder = if (storedName == null) File(root, "assets/sha256/${hash.take(2)}") else File(root, "assets/cheki")
            check(holder.mkdirs() || holder.isDirectory)
            val target = File(holder, storedName ?: hash)
            if (!target.isFile) check(stage.renameTo(target)) { "无法保存媒体文件。" }
            val timestamp = now()
            val metadata = JSONObject().put("id", id).put("kind", kind).put("captureDate", date ?: JSONObject.NULL)
                .put("memberIds", JSONArray(attribution?.takeUnless { it.isGroup }?.let { listOf(it.id) } ?: emptyList<String>()))
                .put("groupId", attribution?.takeIf { it.isGroup }?.id ?: JSONObject.NULL)
                .put("note", note).put("createdAt", timestamp).put("updatedAt", timestamp)
                .put("original", JSONObject().put("sha256", hash).put("byteLength", size).put("mimeType", mimeType)
                    .put("originalFilename", "media$suffix").put("storedFilename", storedName ?: JSONObject.NULL))
            try {
                val records = File(root, "media")
                check(records.mkdirs() || records.isDirectory)
                writeJson(File(records, "$id.json"), metadata)
            } catch (failure: Exception) {
                if (storedName != null) target.delete()
                throw failure
            }
        } finally {
            if (stage.isFile) stage.delete()
        }
    }

    private fun writeJson(file: File, contents: JSONObject) {
        val data = contents.toString(2).toByteArray()
        require(data.size <= maximumMetadata) { "资料记录内容过大。" }
        val atomic = AtomicFile(file)
        val output = atomic.startWrite()
        try {
            output.write(data)
            atomic.finishWrite(output)
        } catch (failure: Exception) {
            atomic.failWrite(output)
            throw failure
        }
    }

    private fun now(): String = Instant.now().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString()

    @Synchronized fun startEditing(id: String): String {
        val token = UUID.randomUUID().toString()
        editingSessions[recordID(id)] = token
        return token
    }

    @Synchronized fun saveDraft(note: Note, session: String) {
        if (editingSessions[note.id] != session) return
        val root = currentFolder()
        File(root, ".drafts").let { check(it.mkdirs() || it.isDirectory) }
        val draft = File(root, ".drafts/${recordID(note.id)}.json")
        writeJson(draft, noteMetadata(note, JSONObject()).put("body", note.body))
    }

    @Synchronized fun closeEditor(note: Note, session: String, save: Boolean): KinenSnapshot {
        if (editingSessions[note.id] == session) {
            if (save) saveDraft(note, session)
            editingSessions.remove(note.id)
        }
        return current()
    }

    @Synchronized fun discardDraft(note: Note, session: String): KinenSnapshot {
        if (editingSessions[note.id] == session) {
            AtomicFile(File(current().root, ".drafts/${recordID(note.id)}.json")).delete()
            editingSessions.remove(note.id)
        }
        return current()
    }

    @Synchronized fun publish(note: Note, session: String): KinenSnapshot {
        check(editingSessions[note.id] == session)
        val snapshot = current()
        val entries = snapshot.notes
        require(note.title.isNotBlank()) { "请填写笔记标题。" }
        val start = LocalDate.parse(note.startDate)
        val end = note.endDate?.let(LocalDate::parse)
        require(end == null || !end.isBefore(start)) { "结束日期不能早于开始日期。" }
        require(note.kind in setOf("journal", "memory", "live", "trip")) { "笔记类型无效。" }
        if (note.parentId != null) {
            val parent = entries.firstOrNull { it.id == note.parentId }
            require(parent != null && parent.id != note.id && acceptsChild(parent.kind, note.kind)) { "上级笔记无效。" }
        }
        require(entries.none { it.parentId == note.id && !acceptsChild(note.kind, it.kind) }) { "笔记仍有关联的下级记录。" }
        require(snapshot.media.map { it.id }.containsAll(note.mediaIds)) { "关联媒体不可用。" }
        require(note.body.toByteArray().size <= maximumMetadata) { "笔记正文过大。" }

        val directory = File(snapshot.root, "entries").apply { check(mkdirs() || isDirectory) }
        val id = recordID(note.id)
        val target = File(directory, id)
        val stage = File(directory, ".${id}.incoming")
        val previous = File(directory, ".${id}.previous")
        check(stage.mkdir())
        try {
            val original = File(target, "entry.json").takeIf(File::isFile)?.let(::json) ?: JSONObject()
            File(stage, "entry.json").writeText(noteMetadata(note, original).toString(2) + "\n")
            File(stage, "body.md").writeText(note.body)
            if (target.exists()) check(target.renameTo(previous)) { "无法更新笔记。" }
            if (!stage.renameTo(target)) {
                if (previous.exists()) previous.renameTo(target)
                error("无法更新笔记。")
            }
            AtomicFile(File(snapshot.root, ".drafts/$id.json")).delete()
            editingSessions.remove(id)
            if (previous.exists()) previous.deleteRecursively()
        } finally {
            if (stage.exists()) stage.deleteRecursively()
        }
        return current()
    }

    private fun noteMetadata(note: Note, existing: JSONObject): JSONObject = existing
        .put("id", note.id).put("title", note.title).put("kind", note.kind)
        .put("startDate", note.startDate).put("endDate", note.endDate ?: JSONObject.NULL)
        .put("parentId", note.parentId ?: JSONObject.NULL).put("mediaIds", JSONArray(note.mediaIds))
        .put("timeZone", existing.optString("timeZone", ZoneId.systemDefault().id))
        .put("createdAt", existing.optString("createdAt", now()))
        .put("updatedAt", now())
        .put("itinerary", JSONArray(note.itinerary.map { stop ->
            JSONObject().put("id", stop.id).put("date", stop.date).put("time", stop.time ?: JSONObject.NULL)
                .put("title", stop.title).put("location", stop.place).put("note", stop.note)
        }))

    private fun repairEntries(directory: File) {
        for (file in directory.listFiles().orEmpty()) {
            when {
                file.name.endsWith(".previous") -> {
                    val target = File(directory, recordID(file.name.removePrefix(".").removeSuffix(".previous")))
                    if (target.exists()) file.deleteRecursively()
                    else check(file.renameTo(target)) { "无法恢复上次未写完的笔记。" }
                }
                file.name.endsWith(".incoming") -> file.deleteRecursively()
            }
        }
    }

    private fun read(root: File): KinenSnapshot {
        verifyManifest(File(root, "library.json"))
        fun subjects(dir: String) = records(root, dir).map { (id, json) -> CollectionSubject(id, json.getString("name")) }
            .sortedBy { it.name }
        val media = records(root, "media").map { (id, json) ->
            Medium(id, json.getString("kind"), json.optional("captureDate"), json.ids("memberIds"),
                json.optional("groupId")?.let(::recordID), json.optString("note"), json.optInt("quarterTurns"),
                attachment(json.getJSONObject("original")), json.optJSONObject("corrected")?.let(::attachment))
        }.sortedByDescending { it.date.orEmpty() }
        val entryDirectory = File(root, "entries")
        repairEntries(entryDirectory)
        val notes = entryDirectory.listFiles().orEmpty().map { directory ->
            val id = recordID(directory.name)
            val metadata = json(File(directory, "entry.json"))
            require(recordID(metadata.getString("id")) == id) { "笔记标识与文件名不一致。" }
            val body = File(directory, "body.md")
            require(body.isFile && body.length() <= maximumMetadata) { "笔记正文无效。" }
            note(metadata, body.readText())
        }.sortedByDescending { it.startDate }
        val drafts = File(root, ".drafts").listFiles().orEmpty().filter { it.extension == "json" }
            .sortedByDescending(File::lastModified).map { file -> json(file).let { note(it, it.getString("body")) } }
        return KinenSnapshot(root, notes, media, subjects("members"), subjects("groups"), drafts)
    }

    private fun note(json: JSONObject, text: String): Note {
        val stops = json.optJSONArray("itinerary")
        val itinerary = (0 until (stops?.length() ?: 0)).map { index ->
            val stop = requireNotNull(stops).getJSONObject(index)
            TravelStop(recordID(stop.getString("id")), stop.getString("date"), stop.optional("time"),
                stop.getString("title"), stop.optString("location"), stop.optString("note"))
        }
        return Note(recordID(json.getString("id")), json.getString("kind"), json.getString("title"),
            json.getString("startDate"), json.optional("endDate"), json.optional("parentId")?.let(::recordID),
            text, json.ids("mediaIds"), itinerary)
    }

    private fun records(root: File, directory: String): List<Pair<String, JSONObject>> =
        File(root, directory).listFiles().orEmpty().map { file ->
            require(file.extension == "json") { "资料记录文件无效。" }
            val id = recordID(file.nameWithoutExtension)
            val data = json(file)
            require(recordID(data.getString("id")) == id) { "资料记录标识与文件名不一致。" }
            id to data
        }

    private fun attachment(json: JSONObject): Attachment {
        val hash = json.getString("sha256")
        require(hash.matches(Regex("[0-9a-f]{64}"))) { "媒体哈希无效。" }
        val bytes = json.getLong("byteLength")
        require(bytes > 0) { "媒体大小无效。" }
        val stored = json.optional("storedFilename")
        val relative = if (stored == null) "assets/sha256/${hash.take(2)}/$hash" else {
            require(stored.matches(Regex("[a-z0-9][a-z0-9_.-]{0,254}"))) { "媒体文件路径无效。" }
            "assets/cheki/$stored"
        }
        return Attachment(relative, hash, bytes)
    }

    private fun verifyManifest(file: File) {
        val manifest = json(file)
        require(manifest.getInt("formatVersion") == 1) { "此资料库版本暂不受支持。" }
        recordID(manifest.getString("libraryId"))
    }

    private fun json(file: File): JSONObject {
        require(file.isFile && file.length() <= maximumMetadata) { "资料记录文件缺失或过大。" }
        return JSONObject(file.readText())
    }

    companion object {
        private const val maximumMetadata = 16L * 1024 * 1024

        private fun recordID(text: String): String {
            val normalized = UUID.fromString(text).toString()
            require(text.lowercase(Locale.ROOT) == normalized) { "资料记录标识无效。" }
            return normalized
        }

        private fun JSONObject.optional(key: String) = if (has(key) && !isNull(key)) getString(key) else null

        private fun JSONObject.ids(key: String): List<String> {
            val array = optJSONArray(key) ?: return emptyList()
            return (0 until array.length()).map { recordID(array.getString(it)) }
        }
    }
}

private class Folder(private val resolver: ContentResolver, private val tree: Uri, private val id: String) {
    val contents: Map<String, Document> by lazy {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)
        val result = mutableMapOf<String, Document>()
        val cursor = requireNotNull(resolver.query(children, columns, null, null, null)) { "无法读取备份文件夹。" }
        cursor.use {
            while (it.moveToNext()) {
                require(result.size < 100_000) { "备份包含过多文件。" }
                val name = it.getString(1)
                require(name != "." && name != ".." && !name.contains('/') && !name.contains('\\')) { "备份文件名无效。" }
                val document = Document(resolver, tree, it.getString(0), it.getString(2))
                require(result.put(name, document) == null) { "备份里有重复的文件名。" }
            }
        }
        result
    }

    fun file(name: String) = requireNotNull(contents[name]) { "备份缺少 $name。" }
    fun directory(name: String) = contents[name]?.asFolder()
}

private class Document(
    private val resolver: ContentResolver, private val tree: Uri, private val id: String, private val type: String
) {
    fun asFolder(): Folder {
        require(type == DocumentsContract.Document.MIME_TYPE_DIR) { "备份目录类型无效。" }
        return Folder(resolver, tree, id)
    }

    fun copyTo(target: File, limit: Long, expected: Attachment? = null) {
        require(type != DocumentsContract.Document.MIME_TYPE_DIR) { "备份文件类型无效。" }
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        val source: InputStream = requireNotNull(resolver.openInputStream(uri)) { "无法读取备份文件。" }
        val hash = expected?.let { MessageDigest.getInstance("SHA-256") }
        var size = 0L
        source.use { input -> target.outputStream().use { output ->
            val bytes = ByteArray(128 * 1024)
            while (true) {
                val count = input.read(bytes)
                if (count < 0) break
                size += count
                require(size <= limit) { "备份文件超过声明的大小。" }
                hash?.update(bytes, 0, count)
                output.write(bytes, 0, count)
            }
        } }
        if (expected != null) {
            val digest = requireNotNull(hash).digest().joinToString("") { "%02x".format(it) }
            require(size == expected.bytes && digest == expected.sha256) { "媒体文件校验失败。" }
        }
    }
}

fun monthCounts(media: List<Medium>): Map<String, Int> =
    media.mapNotNull { item -> item.date?.let { date -> runCatching { LocalDate.parse(date) }.getOrNull() } }
        .groupingBy { "%04d-%02d".format(Locale.ROOT, it.year, it.monthValue) }.eachCount().toSortedMap(reverseOrder())

fun acceptsChild(parent: String, child: String): Boolean =
    (parent == "trip" && (child == "live" || child == "memory")) || (parent == "live" && child == "memory")
