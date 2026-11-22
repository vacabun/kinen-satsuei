package com.vacabun.kinensatsuei

import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Bundle
import android.widget.MediaController
import android.widget.VideoView
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.FileProvider
import java.io.File
import java.time.LocalDate
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val library = KinenLibrary(applicationContext)
        setContent {
            val dark = isSystemInDarkTheme()
            MaterialTheme(colorScheme = if (dark) darkColorScheme(primary = Color.White, onPrimary = Color.Black)
                else lightColorScheme(primary = Color.Black, onPrimary = Color.White)) {
                KinenScreen(library)
            }
        }
    }
}

private enum class Page(val label: String, val icon: ImageVector) {
    Notes("笔记", Icons.Default.Edit), Media("媒体", Icons.Default.PlayArrow),
    Add("添加", Icons.Default.AddCircle), Collection("收藏", Icons.Default.Favorite), Settings("设置", Icons.Default.Settings)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KinenScreen(library: KinenLibrary) {
    val scope = rememberCoroutineScope()
    var snapshot by remember { mutableStateOf<KinenSnapshot?>(null) }
    var page by remember { mutableStateOf(Page.Notes) }
    var note by remember { mutableStateOf<Note?>(null) }
    var medium by remember { mutableStateOf<Medium?>(null) }
    var editor by remember { mutableStateOf<NoteEditSession?>(null) }
    fun startEditor(entry: Note) {
        editor = NoteEditSession(entry, library.startEditing(entry.id))
    }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var showSources by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf<MediaImportRequest?>(null) }
    var cameraPath by rememberSaveable { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { urls ->
        if (urls.isNotEmpty()) importing = MediaImportRequest(urls.distinct(), captured = false)
    }
    val takePicture = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { taken ->
        val file = cameraPath?.let(::File)
        cameraPath = null
        if (file != null) {
            if (taken && file.length() > 0) {
                val uri = FileProvider.getUriForFile(context, context.packageName + ".media", file)
                importing = MediaImportRequest(listOf(uri), captured = true, temporary = file)
            } else {
                file.delete()
                if (taken) message = "相机没有返回有效的照片。"
            }
        }
    }
    val openFolder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null && !busy) {
            busy = true
            scope.launch {
                try {
                    snapshot = withContext(Dispatchers.IO) { library.restore(uri) }
                    message = "备份已恢复。"
                } catch (error: Exception) {
                    message = error.localizedMessage ?: "无法恢复所选资料库。"
                } finally { busy = false }
            }
        }
    }
    LaunchedEffect(library) {
        try { snapshot = withContext(Dispatchers.IO) { library.current() } }
        catch (error: Exception) { message = error.localizedMessage ?: "无法读取资料库。" }
    }
    BackHandler(importing == null && editor == null && (note != null || medium != null)) {
        if (medium != null) medium = null else note = null
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(when {
                        importing != null -> "媒体预览"
                        editor != null -> "编辑笔记"
                        else -> medium?.kind?.let(::kindLabel) ?: note?.title ?: "記念撮影"
                    })
                },
                actions = {
                    if (importing == null && editor == null && snapshot != null && medium == null && page == Page.Notes) {
                        val original = note
                        if (original != null) TextButton(onClick = {
                            startEditor(snapshot?.drafts?.firstOrNull { it.id == original.id } ?: original)
                        }) { Text("编辑") }
                        else TextButton(onClick = {
                            startEditor(Note(UUID.randomUUID().toString(), "journal", "", LocalDate.now().toString(),
                                null, null, "", emptyList(), emptyList()))
                        }) { Text("新建笔记") }
                    }
                },
                navigationIcon = {
                    if (importing == null && editor == null && (note != null || medium != null)) {
                        TextButton(onClick = { if (medium != null) medium = null else note = null }) { Text("返回") }
                    }
                }
            )
        },
        bottomBar = {
            if (importing == null && editor == null && note == null && medium == null) {
                NavigationBar {
                    Page.entries.forEach { tab ->
                        NavigationBarItem(selected = page == tab, onClick = {
                                if (tab == Page.Add) showSources = true else page = tab
                            }, enabled = !busy && snapshot != null,
                            label = { Text(tab.label) }, icon = { Icon(tab.icon, contentDescription = null) })
                    }
                }
            }
        }
    ) { padding ->
        val loaded = snapshot
        val activeNote = note
        val activeMedium = medium
        val currentEditor = editor
        val request = importing
        Box(Modifier.padding(padding).fillMaxSize()) {
            if (busy || loaded == null) {
                Column(Modifier.padding(20.dp)) {
                    if (busy || message == null) LinearProgressIndicator(Modifier.fillMaxWidth())
                    if (loaded == null && !busy) TextButton(onClick = { openFolder.launch(null) }) { Text("恢复资料库") }
                }
            } else if (request != null) {
                MediaImportScreen(library, loaded, request,
                    onSnapshot = { snapshot = it },
                    onClose = { changed ->
                        request.temporary?.delete()
                        importing = null
                        if (changed) page = Page.Media
                    })
            } else if (currentEditor != null) {
                key(currentEditor.token) {
                    NoteEditor(library, loaded, currentEditor) { updated ->
                        snapshot = updated
                        note = activeNote?.let { old -> updated.notes.firstOrNull { it.id == old.id } }
                        editor = null
                    }
                }
            } else if (activeMedium != null) {
                MediaDetail(loaded, activeMedium)
            } else if (activeNote != null) {
                NoteDetail(loaded, activeNote, onNote = { note = it }, onMedia = { medium = it })
            } else {
                when (page) {
                    Page.Notes -> NoteList(loaded.notes, loaded.drafts, open = { note = it }, openDraft = ::startEditor)
                    Page.Media -> MediaList(loaded, loaded.media) { medium = it }
                    Page.Collection -> Collection(loaded) { medium = it }
                    Page.Add -> Unit
                    Page.Settings -> Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("资料库", style = MaterialTheme.typography.titleLarge)
                        Text("${loaded.notes.size} 篇笔记 · ${loaded.media.size} 项媒体")
                        Button(onClick = { openFolder.launch(null) }) { Text("恢复备份文件夹") }
                        if (loaded.root.name != "default") {
                            OutlinedButton(onClick = {
                                busy = true
                                scope.launch {
                                    try { snapshot = withContext(Dispatchers.IO) { library.useDefault() } }
                                    catch (error: Exception) { message = error.localizedMessage }
                                    finally { busy = false }
                                }
                            }) { Text("返回默认资料库") }
                        }
                        Text("选择包含 library.json 的备份文件夹。恢复结果会保存在独立的本机资料库中。")
                    }
                }
            }
        }
    }
    if (showSources) {
        AlertDialog(onDismissRequest = { showSources = false }, title = { Text("添加媒体") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = {
                        showSources = false
                        pickMedia.launch(arrayOf("image/*", "video/*"))
                    }, modifier = Modifier.fillMaxWidth()) { Text("从相册或文件导入") }
                    OutlinedButton(onClick = {
                        showSources = false
                        var pending: File? = null
                        try {
                            val folder = File(context.cacheDir, "captures").apply { check(mkdirs() || isDirectory) }
                            val file = File.createTempFile("cheki-", ".jpg", folder)
                            pending = file
                            cameraPath = file.absolutePath
                            takePicture.launch(FileProvider.getUriForFile(context, context.packageName + ".media", file))
                        } catch (error: Exception) {
                            pending?.delete()
                            cameraPath = null
                            message = "无法启动系统相机。"
                        }
                    }, modifier = Modifier.fillMaxWidth()) { Text("拍摄拍立得") }
                }
            }, confirmButton = { TextButton(onClick = { showSources = false }) { Text("关闭") } })
    }
    message?.let {
        AlertDialog(onDismissRequest = { message = null }, title = { Text("記念撮影") },
            text = { Text(it) }, confirmButton = { TextButton(onClick = { message = null }) { Text("好") } })
    }
}

@Composable
private fun NoteList(notes: List<Note>, drafts: List<Note>, open: (Note) -> Unit, openDraft: (Note) -> Unit) {
    var query by remember { mutableStateOf("") }
    fun matches(note: Note): Boolean =
        query.isBlank() || listOf(note.title, note.body, note.startDate).any { it.contains(query.trim(), ignoreCase = true) } ||
            note.itinerary.any { it.title.contains(query.trim(), true) || it.place.contains(query.trim(), true) }
    val results = notes.filter(::matches)
    val localDrafts = drafts.filter(::matches)
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), singleLine = true,
            label = { Text("搜索笔记") }) }
        if (results.isEmpty() && localDrafts.isEmpty()) item { Text("没有笔记", Modifier.padding(12.dp)) }
        if (localDrafts.isNotEmpty()) item { Text("草稿", style = MaterialTheme.typography.titleSmall) }
        items(localDrafts, key = { "draft-" + it.id }) { draft ->
            ListItem(headlineContent = { Text(draft.title.ifBlank { "未命名笔记" }) },
                supportingContent = { Text(kindLabel(draft.kind)) }, modifier = Modifier.clickable { openDraft(draft) })
        }
        if (results.isNotEmpty()) item { Text("已完成", style = MaterialTheme.typography.titleSmall) }
        items(results, key = { it.id }) { note ->
            ListItem(headlineContent = { Text(note.title) },
                supportingContent = { Text("${kindLabel(note.kind)} · ${note.startDate}") },
                modifier = Modifier.clickable { open(note) })
        }
    }
}

@Composable
private fun NoteDetail(snapshot: KinenSnapshot, note: Note, onNote: (Note) -> Unit, onMedia: (Medium) -> Unit) {
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Text(listOfNotNull(kindLabel(note.kind), note.startDate, note.endDate).joinToString(" · "),
                style = MaterialTheme.typography.labelLarge)
        }
        if (note.body.isNotBlank()) item { Text(note.body) }
        items(note.itinerary.sortedWith(compareBy({ it.date }, { it.time ?: "24:00" }))) { stop ->
            ListItem(headlineContent = { Text(stop.title) }, supportingContent = {
                Text(listOfNotNull(stop.date, stop.time, stop.place, stop.note).filter(String::isNotBlank).joinToString(" · "))
            })
        }
        items(snapshot.notes.filter { it.parentId == note.id }, key = { it.id }) { child ->
            OutlinedButton(onClick = { onNote(child) }) { Text(child.title) }
        }
        items(snapshot.media.filter { it.id in note.mediaIds }, key = { it.id }) { item ->
            OutlinedButton(onClick = { onMedia(item) }) { Text("${kindLabel(item.kind)} · ${item.date ?: "日期未知"}") }
        }
    }
}

@Composable
private fun MediaList(snapshot: KinenSnapshot, photos: List<Medium>, open: (Medium) -> Unit) {
    LazyColumn(contentPadding = PaddingValues(16.dp)) {
        if (photos.isEmpty()) item { Text("没有媒体") }
        items(photos, key = { it.id }) { item -> MediaRow(snapshot, item, open) }
    }
}

@Composable
private fun MediaRow(snapshot: KinenSnapshot, item: Medium, open: (Medium) -> Unit) {
    ListItem(headlineContent = {
        Text(snapshot.names(item).joinToString("、").ifEmpty { kindLabel(item.kind) })
    }, supportingContent = { Text(item.date ?: "日期未知") }, modifier = Modifier.clickable { open(item) })
}

@Composable
private fun MediaDetail(snapshot: KinenSnapshot, item: Medium) {
    val file = snapshot.attachment(item)
    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (!file.isFile) Text("附件不可用")
        else if (item.kind == "video") {
            AndroidView(factory = { context ->
                VideoView(context).apply {
                    setVideoPath(file.absolutePath)
                    val controller = MediaController(context)
                    controller.setAnchorView(this)
                    setMediaController(controller)
                    setOnPreparedListener { seekTo(1) }
                }
            }, modifier = Modifier.fillMaxWidth().height(240.dp))
        } else {
            var image by remember(file) { mutableStateOf<android.graphics.Bitmap?>(null) }
            LaunchedEffect(file) {
                image = withContext(Dispatchers.IO) {
                    decodePhoto(ImageDecoder.createSource(file), maxPixels = 1800)
                }
            }
            image?.let { Image(it.asImageBitmap(), kindLabel(item.kind),
                Modifier.fillMaxWidth().heightIn(max = 360.dp).rotate(90f * item.rotation)) }
        }
        Text(listOfNotNull(item.date, snapshot.names(item).joinToString("、").ifEmpty { null }).joinToString(" · "))
        if (item.note.isNotEmpty()) Text(item.note)
    }
}

@Composable
private fun Collection(snapshot: KinenSnapshot, open: (Medium) -> Unit) {
    var selected by remember { mutableStateOf<String?>(null) }
    val filter = selected
    val photos = snapshot.media.filter {
        it.kind == "cheki" && (filter == null || filter == it.groupId || filter in it.memberIds)
    }
    LazyColumn(contentPadding = PaddingValues(16.dp)) {
        item {
            Text("拍立得 · ${photos.size} 张", style = MaterialTheme.typography.titleLarge)
            if (selected != null) TextButton(onClick = { selected = null }) { Text("显示全部") }
        }
        items(snapshot.members + snapshot.groups, key = { it.id }) { subject ->
            TextButton(onClick = { selected = if (selected == subject.id) null else subject.id }) { Text(subject.name) }
        }
        monthCounts(photos).forEach { (month, count) ->
            item(key = month) { ListItem(headlineContent = { Text(month) }, trailingContent = { Text("$count 张") }) }
        }
        items(photos, key = { it.id }) { item -> MediaRow(snapshot, item, open) }
    }
}

internal fun kindLabel(kind: String) = when (kind) {
    "cheki" -> "拍立得"
    "portrait" -> "合影"
    "photo" -> "照片"
    "video" -> "视频"
    "trip" -> "旅行"
    "live" -> "Live"
    "memory" -> "合影回忆"
    else -> "笔记"
}
