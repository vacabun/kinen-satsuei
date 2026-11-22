package com.vacabun.kinensatsuei

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.LocalDate

internal data class MediaImportRequest(val uris: List<Uri>, val captured: Boolean, val temporary: File? = null)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MediaImportScreen(
    library: KinenLibrary,
    snapshot: KinenSnapshot,
    request: MediaImportRequest,
    onSnapshot: (KinenSnapshot) -> Unit,
    onClose: (Boolean) -> Unit
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var files by remember { mutableStateOf<List<Pair<Uri, String>>?>(null) }
    var imageKind by remember { mutableStateOf(if (request.captured) "cheki" else "photo") }
    var attribution by remember { mutableStateOf<MediaAttribution?>(null) }
    var date by remember { mutableStateOf(LocalDate.now().toString()) }
    var knowsDate by remember { mutableStateOf(request.captured) }
    var notes by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var savedSome by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var subjectMenu by remember { mutableStateOf(false) }
    var newKind by remember { mutableStateOf<Boolean?>(null) }
    var subjectName by remember { mutableStateOf("") }

    LaunchedEffect(request) {
        val supported = withContext(Dispatchers.IO) {
            request.uris.mapNotNull { uri ->
                val type = if (request.captured) "image/jpeg" else runCatching { library.mediaType(uri) }.getOrNull()
                type?.let { uri to it }
            }
        }
        files = supported
        if (supported.size != request.uris.size) error = "部分文件无法识别为照片或视频。"
    }
    BackHandler { if (!saving) onClose(savedSome) }

    val options = files.orEmpty()
    val hasImages = options.any { it.second.startsWith("image/") }
    val cheki = hasImages && imageKind == "cheki"
    val firstImage = options.firstOrNull { it.second.startsWith("image/") }?.first
    var thumbnail by remember(firstImage) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(firstImage) {
        thumbnail = firstImage?.let { uri ->
            withContext(Dispatchers.IO) { decodePhoto(ImageDecoder.createSource(context.contentResolver, uri), 800) }
        }
    }

    Column(Modifier.fillMaxSize()) {
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            if (files == null) LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("已选择 ${options.size} 项", style = MaterialTheme.typography.titleLarge)
            thumbnail?.let { Image(it.asImageBitmap(), "照片预览", Modifier.fillMaxWidth().heightIn(max = 260.dp)) }
            if (hasImages) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (kind in listOf("photo", "portrait", "cheki")) {
                        FilterChip(selected = imageKind == kind, enabled = !saving, onClick = { imageKind = kind },
                            label = { Text(kindLabel(kind)) })
                    }
                }
            }
            if (cheki) {
                val selected = attribution
                val name = if (selected?.isGroup == true) snapshot.groups.firstOrNull { it.id == selected.id }?.name
                    else snapshot.members.firstOrNull { it.id == selected?.id }?.name
                Box {
                    OutlinedButton(enabled = !saving, onClick = { subjectMenu = true }) { Text(name ?: "选择成员或团体") }
                    DropdownMenu(expanded = subjectMenu, onDismissRequest = { subjectMenu = false }) {
                        for (member in snapshot.members) {
                            DropdownMenuItem(text = { Text("${member.name} · 成员") }, onClick = {
                                attribution = MediaAttribution(member.id, false)
                                subjectMenu = false
                            })
                        }
                        for (group in snapshot.groups) {
                            DropdownMenuItem(text = { Text("${group.name} · 团体") }, onClick = {
                                attribution = MediaAttribution(group.id, true)
                                subjectMenu = false
                            })
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(enabled = !saving, onClick = { subjectName = ""; newKind = false }) { Text("新增成员") }
                    TextButton(enabled = !saving, onClick = { subjectName = ""; newKind = true }) { Text("新增团体") }
                }
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Checkbox(checked = knowsDate, onCheckedChange = { knowsDate = it }, enabled = !saving)
                    Text("知道拍摄日期", Modifier.padding(top = 12.dp))
                }
            }
            if (cheki || knowsDate) {
                OutlinedTextField(date, { date = it }, Modifier.fillMaxWidth(), label = { Text("拍摄日期（YYYY-MM-DD）") },
                    singleLine = true, enabled = !saving)
            }
            OutlinedTextField(notes, { notes = it }, Modifier.fillMaxWidth(), label = { Text("回忆备注") }, enabled = !saving)
            if (error != null) Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
        }
        Surface(tonalElevation = 2.dp) {
            Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (saving) CircularProgressIndicator(Modifier.size(26.dp))
                Spacer(Modifier.weight(1f))
                OutlinedButton(enabled = !saving, onClick = { onClose(savedSome) }) { Text("取消") }
                Button(enabled = !saving && options.isNotEmpty() && (!cheki || attribution != null), onClick = {
                    val photoDate = if (cheki || knowsDate) runCatching { LocalDate.parse(date).toString() }.getOrNull() else null
                    if ((cheki || knowsDate) && photoDate == null) {
                        error = "请输入有效的拍摄日期。"
                    } else {
                        saving = true
                        error = null
                        val kind = imageKind
                        val subject = attribution
                        val note = notes
                        scope.launch {
                            val failures = mutableListOf<Pair<Uri, String>>()
                            var failureMessage: String? = null
                            withContext(Dispatchers.IO) {
                                for ((uri, type) in options) {
                                    val selected = if (type.startsWith("video/")) "video" else kind
                                    try {
                                        library.importMedia(uri, type, selected, photoDate,
                                            subject.takeIf { selected == "cheki" }, note)
                                    } catch (problem: Exception) {
                                        if (problem is CancellationException) throw problem
                                        failures.add(uri to type)
                                        failureMessage = problem.localizedMessage
                                    }
                                }
                            }
                            savedSome = savedSome || failures.size < options.size
                            try { onSnapshot(withContext(Dispatchers.IO) { library.current() }) }
                            catch (problem: Exception) {
                                if (problem is CancellationException) throw problem
                                failureMessage = problem.localizedMessage
                            }
                            saving = false
                            if (failures.isEmpty() && failureMessage == null) onClose(savedSome)
                            else {
                                files = failures
                                error = failureMessage ?: "部分媒体保存失败，可以重试剩余项目。"
                            }
                        }
                    }
                }) { Text("保存媒体") }
            }
        }
    }

    newKind?.let { group ->
        AlertDialog(onDismissRequest = { newKind = null }, title = { Text(if (group) "新增团体" else "新增成员") },
            text = { OutlinedTextField(subjectName, { subjectName = it }, label = { Text("名称") }) },
            confirmButton = {
                TextButton(enabled = subjectName.isNotBlank(), onClick = {
                    val name = subjectName
                    newKind = null
                    saving = true
                    scope.launch {
                        try {
                            attribution = withContext(Dispatchers.IO) { library.addSubject(name, group) }
                            onSnapshot(withContext(Dispatchers.IO) { library.current() })
                        } catch (problem: Exception) {
                            if (problem is CancellationException) throw problem
                            error = problem.localizedMessage
                        } finally { saving = false }
                    }
                }) { Text("新增") }
            }, dismissButton = { TextButton(onClick = { newKind = null }) { Text("取消") } })
    }
}

internal fun decodePhoto(source: ImageDecoder.Source, maxPixels: Int): Bitmap? =
    runCatching {
        ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val width = info.size.width
            val height = info.size.height
            val largest = maxOf(width, height)
            if (largest > maxPixels) {
                val scale = maxPixels.toDouble() / largest
                decoder.setTargetSize((width * scale).toInt().coerceAtLeast(1), (height * scale).toInt().coerceAtLeast(1))
            }
        }
    }.getOrNull()
