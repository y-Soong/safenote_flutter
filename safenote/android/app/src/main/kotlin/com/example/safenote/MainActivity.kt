package com.example.safenote

import android.Manifest
import android.content.pm.PackageManager
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import android.util.Log

class MainActivity : FlutterActivity() {
    private val PERMISSION_CODE = 1001

    override fun onResume() {
        super.onResume()
        checkAndRequestPermissions()

        // ✅ WebView 내 권한요청(JS→Android 연결)
        WebView(this).webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                runOnUiThread {
                    Log.d("SafeNote", "✅ JS 요청 권한: ${request.resources.joinToString()}")
                    request.grant(request.resources)
                }
            }
        }
    }

    private fun checkAndRequestPermissions() {
        val perms = arrayOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO
        )

        val need = perms.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (need.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, need.toTypedArray(), PERMISSION_CODE)
        }
    }
}
